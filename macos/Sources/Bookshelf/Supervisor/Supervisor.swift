import Foundation

/// Starts and stops the repo's services (§3, §4): Postgres through `scripts/pg-local.sh`,
/// then the API, and in parallel the compiled web server, each under a guard.
@MainActor
final class Supervisor {
    enum Step: String, CaseIterable, Sendable {
        case database = "Database"
        case api = "API"
        case web = "Web"
    }

    enum StepState: Equatable, Sendable {
        case waiting
        case working(String)
        case done
        case failed
    }

    enum Phase: Equatable, Sendable {
        case idle, starting, ready, stopping, failed
    }

    enum StartResult: Equatable, Sendable {
        case ready
        case failed(StartFailure)
        /// A quit came while starting.
        case cancelled
    }

    let paths: AppPaths
    let preferences: Preferences
    private(set) var phase: Phase = .idle
    private(set) var steps: [Step: StepState] = [:]
    private(set) var context: LaunchContext?
    private var services: [ServiceID: GuardedService] = [:]
    private var activity: NSObjectProtocol?

    /// Steps or phase changed.
    var onChange: (() -> Void)?
    /// A service stopped by itself after the start.
    var onServiceDied: ((StartFailure) -> Void)?

    init(paths: AppPaths, preferences: Preferences) {
        self.paths = paths
        self.preferences = preferences
    }

    private var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    func state(of step: Step) -> StepState { steps[step] ?? .waiting }

    // MARK: Start

    func start() async -> StartResult {
        guard phase == .idle || phase == .failed else { return .cancelled }
        let started = ContinuousClock.now
        phase = .starting
        steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
        changed()

        switch await Preflight.run(paths: paths, preferences: preferences, executable: executable) {
        case .failure(let failure): return fail(failure)
        case .success(let context): self.context = context
        }
        guard phase == .starting, let context else { return .cancelled }

        async let backend = startBackend(context)
        async let web = startWeb(context, forceBuild: false)
        let failures = [await backend, await web].compactMap { $0 }
        guard phase == .starting else { return .cancelled }
        if let failure = failures.first {
            await stopServices()
            return fail(failure)
        }
        phase = .ready
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Bookshelf runs its services")
        changed()
        Log.info("ready in \(started.duration(to: .now))", .supervisor)
        return .ready
    }

    /// Postgres, then the API.
    private func startBackend(_ context: LaunchContext) async -> StartFailure? {
        set(.database, .working("Starting"))
        let database = await Command.run(
            ["/bin/bash", context.repo.pgScript.path, "start"],
            env: context.environment, cwd: context.repo.root, log: paths.log(.setup), timeout: .seconds(120)
        )
        guard database.succeeded, Ports.accepts(Loopback.databasePort) else {
            set(.database, .failed)
            let log = FileManager.default.fileExists(atPath: context.repo.pgLog.path) ? context.repo.pgLog : paths.log(.setup)
            return StartFailure(step: .database, message: "Postgres did not start (scripts/pg-local.sh start).", log: log)
        }
        set(.database, .done)
        return await launch(.api(repo: context.repo, tools: context.tools), step: .api, context: context)
    }

    /// `astro build` when there is no compiled web yet (or when asked), then the web server.
    private func startWeb(_ context: LaunchContext, forceBuild: Bool) async -> StartFailure? {
        let repo = context.repo
        if forceBuild || !FileManager.default.fileExists(atPath: repo.webEntry.path) {
            set(.web, .working("Building"))
            let build = await Command.run(
                [context.tools.pnpm, "exec", "astro", "build"],
                env: context.environment, cwd: repo.frontend, log: paths.log(.webBuild), timeout: .seconds(600)
            )
            guard build.succeeded else {
                set(.web, .failed)
                return StartFailure(step: .web, message: "The web build failed (astro build).", log: paths.log(.webBuild))
            }
        }
        let hasEnv = FileManager.default.fileExists(atPath: repo.webEnvFile.path)
        return await launch(.web(repo: repo, tools: context.tools, hasEnvFile: hasEnv), step: .web, context: context)
    }

    private func launch(_ spec: LaunchSpec, step: Step, context: LaunchContext) async -> StartFailure? {
        guard phase == .starting || phase == .ready else { return nil }  // a quit came first
        set(step, .working("Starting"))
        let name = step == .api ? "API" : "web server"
        let service = GuardedService(spec: spec)
        service.onUnexpectedExit = { [weak self] status in self?.serviceDied(step, spec: spec, status: status) }
        do {
            try service.start(executable: executable, environment: context.environment, paths: paths)
        } catch {
            set(step, .failed)
            return StartFailure(step: step, message: "The \(name) could not start: \(error)", log: paths.log(spec.log))
        }
        services[spec.id] = service
        let since = ContinuousClock.now
        switch await Readiness.wait(for: spec.readyURL, timeout: spec.readyTimeout, alive: { service.isRunning }) {
        case .ready:
            set(step, .done)
            Log.info("\(spec.id.rawValue) ready in \(since.duration(to: .now)) (guard \(service.pid))", .supervisor)
            return nil
        case .died:
            set(step, .failed)
            return StartFailure(step: step, message: "The \(name) stopped while starting.", log: paths.log(spec.log))
        case .timedOut:
            set(step, .failed)
            return StartFailure(step: step, message: "The \(name) did not answer within \(spec.readyTimeout).", log: paths.log(spec.log))
        }
    }

    // MARK: Stop

    /// The web server, then the API (§3), in `budget` overall; what is left after it is
    /// killed. Postgres keeps running unless *Keep the database running after quit* is off.
    func shutdown(budget: Duration = .seconds(7)) async {
        phase = .stopping
        changed()
        await stopServices(budget: budget)
        if !preferences.keepDatabaseRunning, let context {
            Log.info("stopping Postgres (Keep the database running after quit is off)", .supervisor)
            _ = await Command.run(["/bin/bash", context.repo.pgScript.path, "stop"], env: context.environment, cwd: context.repo.root, log: paths.log(.setup), timeout: .seconds(15))
        }
        phase = .idle
        changed()
    }

    func stopServices(budget: Duration = .seconds(7)) async {
        let deadline = ContinuousClock.now + budget
        for id in [ServiceID.web, .api] {
            guard let service = services.removeValue(forKey: id), service.isRunning else { continue }
            let since = ContinuousClock.now
            if await service.stop(timeout: max(deadline - .now, .zero)) {
                Log.info("\(id.rawValue) stopped in \(since.duration(to: .now))", .supervisor)
            } else {
                Log.error("\(id.rawValue) still running when the stop budget ran out: SIGKILL to its group", .supervisor)
                await service.forceKill()
            }
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: Restarts (Server menu, Retry)

    func restartServices() async -> StartResult {
        guard phase != .starting, phase != .stopping else { return .cancelled }
        await stopServices()
        phase = .idle
        return await start()
    }

    /// Stops one running service and starts it again; the web is rebuilt first when `rebuild`.
    func restart(_ id: ServiceID, rebuild: Bool = false) async -> StartFailure? {
        guard phase == .ready, let context, let service = services.removeValue(forKey: id) else { return nil }
        _ = await service.stop(timeout: .seconds(7))
        if service.isRunning { await service.forceKill() }
        let failure = switch id {
        case .api: await launch(.api(repo: context.repo, tools: context.tools), step: .api, context: context)
        case .web: await startWeb(context, forceBuild: rebuild)
        }
        if failure != nil {
            phase = .failed
            changed()
        }
        return failure
    }

    // MARK: State

    private func serviceDied(_ step: Step, spec: LaunchSpec, status: Int32) {
        Log.error("\(spec.id.rawValue) guard exited with status \(status) (phase \(phase))", .supervisor)
        services[spec.id] = nil
        guard phase == .ready else { return }  // while starting, the readiness wait reports it
        phase = .failed
        set(step, .failed)
        let name = step == .api ? "API" : "web server"
        onServiceDied?(StartFailure(step: step, message: "The \(name) stopped unexpectedly (status \(status)).", log: paths.log(spec.log)))
    }

    private func fail(_ failure: StartFailure) -> StartResult {
        guard phase == .starting else { return .cancelled }
        Log.error("start failed: \(failure.message)", .supervisor)
        phase = .failed
        changed()
        return .failed(failure)
    }

    private func set(_ step: Step, _ state: StepState) {
        steps[step] = state
        changed()
    }

    private func changed() {
        onChange?()
    }
}
