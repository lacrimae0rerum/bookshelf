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

    /// `.starting` covers every start and restart: one at a time, and no menu offers another.
    enum Phase: Equatable, Sendable {
        case idle, starting, ready, stopping, failed
    }

    enum StartResult: Equatable, Sendable {
        case ready
        case failed(StartFailure)
        /// A quit, or a newer start, came first.
        case cancelled
    }

    /// The API's guard needs up to 6 s (SIGTERM, 5 s, SIGINT, 1 s, SIGKILL); the stop
    /// budget always leaves it that much, whatever the web does first.
    static let apiStopWindow: Duration = .milliseconds(6_200)

    let paths: AppPaths
    let preferences: Preferences
    private(set) var phase: Phase = .idle
    private(set) var steps: [Step: StepState] = [:]
    private(set) var context: LaunchContext?
    private var services: [ServiceID: GuardedService] = [:]
    private var activity: NSObjectProtocol?
    /// Bumped by every start: a branch of an older start never launches anything.
    private var generation = 0

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
        generation += 1
        let current = generation
        phase = .starting
        steps = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
        changed()

        switch await Preflight.run(paths: paths, preferences: preferences, executable: executable) {
        case .failure(let failure): return fail(failure, generation: current)
        case .success(let context): self.context = context
        }
        guard phase == .starting, generation == current, let context else { return .cancelled }

        // The two branches run in parallel; the first failure ends the start (§3) without
        // waiting for the other branch, which then launches nothing (`launch` checks).
        let first = Eventual<StartFailure?>()
        let pending = Countdown(2)
        let report: @MainActor (StartFailure?) -> Void = { failure in
            if let failure { first.fulfill(failure) } else if pending.tick() { first.fulfill(nil) }
        }
        Task { report(await startBackend(context, current)) }
        Task { report(await startWeb(context, current, forceBuild: false)) }
        let failure = await first.value() ?? nil
        guard phase == .starting, generation == current else { return .cancelled }
        if let failure {
            await stopServices()
            return fail(failure, generation: current)
        }
        phase = .ready
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Bookshelf runs its services")
        changed()
        Log.info("ready in \(started.duration(to: .now))", .supervisor)
        return .ready
    }

    /// Postgres, then the API.
    private func startBackend(_ context: LaunchContext, _ generation: Int) async -> StartFailure? {
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
        return await launch(.api(repo: context.repo, tools: context.tools), step: .api, context: context, generation: generation)
    }

    /// `astro build` when there is no compiled web yet (or when asked), then the web server.
    private func startWeb(_ context: LaunchContext, _ generation: Int, forceBuild: Bool) async -> StartFailure? {
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
        return await launch(.web(repo: repo, tools: context.tools, hasEnvFile: hasEnv), step: .web, context: context, generation: generation)
    }

    private func launch(_ spec: LaunchSpec, step: Step, context: LaunchContext, generation: Int) async -> StartFailure? {
        // A quit, a failure in the other branch, or a newer start came first.
        guard phase == .starting, generation == self.generation else { return nil }
        set(step, .working("Starting"))
        let name = step == .api ? "API" : "web server"
        let service = GuardedService(spec: spec)
        service.onUnexpectedExit = { [weak self, weak service] status in
            guard let self, let service else { return }
            serviceDied(service, step: step, status: status)
        }
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
            _ = await Command.run(["/bin/bash", context.repo.pgScript.path, "stop"], env: context.environment, cwd: context.repo.root, log: paths.log(.setup), timeout: .seconds(5))
        }
        phase = .idle
        changed()
    }

    /// The web first; the API's stop starts when the web is gone, or when waiting longer
    /// would leave the API less than `apiStopWindow` of the budget.
    func stopServices(budget: Duration = .seconds(7)) async {
        let deadline = ContinuousClock.now + budget
        let web = services.removeValue(forKey: .web)
        let api = services.removeValue(forKey: .api)
        let webStopped = Task { await stop(web, .web, until: deadline) }
        if web?.isRunning == true {
            _ = await web?.waitExit(timeout: max(deadline - Self.apiStopWindow - .now, .zero))
        }
        await stop(api, .api, until: deadline)
        await webStopped.value
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func stop(_ service: GuardedService?, _ id: ServiceID, until deadline: ContinuousClock.Instant) async {
        guard let service, service.isRunning else { return }
        let since = ContinuousClock.now
        if await service.stop(timeout: max(deadline - .now, .zero)) {
            Log.info("\(id.rawValue) stopped in \(since.duration(to: .now))", .supervisor)
        } else {
            Log.error("\(id.rawValue) still running when the stop budget ran out: SIGKILL to its group", .supervisor)
            await service.forceKill()
        }
    }

    // MARK: Restarts (Server menu, Retry)

    func restartServices() async -> StartResult {
        guard phase == .ready || phase == .failed else { return .cancelled }
        phase = .stopping  // before the first await: no second restart meanwhile
        changed()
        await stopServices()
        phase = .idle
        return await start()
    }

    /// Stops one running service and starts it again; the web is rebuilt first when `rebuild`.
    func restart(_ id: ServiceID, rebuild: Bool = false) async -> StartFailure? {
        guard phase == .ready, let context, let service = services.removeValue(forKey: id) else { return nil }
        phase = .starting
        changed()
        _ = await service.stop(timeout: .seconds(7))
        if service.isRunning { await service.forceKill() }
        let failure = switch id {
        case .api: await launch(.api(repo: context.repo, tools: context.tools), step: .api, context: context, generation: generation)
        case .web: await startWeb(context, generation, forceBuild: rebuild)
        }
        if phase == .starting {  // not overtaken by a quit
            phase = failure == nil ? .ready : .failed
            changed()
        }
        return failure
    }

    // MARK: State

    private func serviceDied(_ service: GuardedService, step: Step, status: Int32) {
        let id = service.spec.id
        Log.error("\(id.rawValue) guard exited with status \(status) (phase \(phase))", .supervisor)
        guard services[id] === service else { return }  // an older one; its slot is taken
        services[id] = nil
        guard phase == .ready else { return }  // while starting, the readiness wait reports it
        phase = .failed
        set(step, .failed)
        let name = step == .api ? "API" : "web server"
        onServiceDied?(StartFailure(step: step, message: "The \(name) stopped unexpectedly (status \(status)).", log: paths.log(service.spec.log)))
    }

    private func fail(_ failure: StartFailure, generation: Int) -> StartResult {
        guard phase == .starting, generation == self.generation else { return .cancelled }
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

/// Counts finished branches down to zero.
@MainActor
private final class Countdown {
    private var left: Int

    init(_ count: Int) {
        left = count
    }

    /// `true` for the tick that reaches zero.
    func tick() -> Bool {
        left -= 1
        return left == 0
    }
}
