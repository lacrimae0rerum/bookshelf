import Darwin
import Foundation

/// The app's side of one guard (M8): the guard leads its own process group, so the app
/// stops a service by signalling the guard, and a Force Quit of the app is seen by the
/// guard's kqueue, not by the app.
@MainActor
final class GuardedService {
    let spec: LaunchSpec
    private(set) var pid: pid_t = 0
    private(set) var stopRequested = false
    private let exitStatus = Eventual<Int32>()
    private var source: DispatchSourceProcess?
    private var pidFile: URL?

    /// Called once, when the guard exits without having been asked to.
    var onUnexpectedExit: ((Int32) -> Void)?

    init(spec: LaunchSpec) {
        self.spec = spec
    }

    var isRunning: Bool { pid > 0 && !exitStatus.isSet }

    /// `executable --guard <app-pid> -- <spec.argv…>`, output appended to the service's log.
    func start(executable: String, environment: [String: String], paths: AppPaths) throws {
        let argv = [executable, Guard.flag, "\(getpid())", "--"] + spec.argv
        let env = environment.merging(spec.extraEnv) { _, new in new }
        pid = try Spawn.run(argv, env: env, cwd: spec.cwd.path, output: .file(paths.log(spec.log).path), newGroup: true)
        let file = paths.pidFile(spec.id)
        try? "\(pid)\n".write(to: file, atomically: true, encoding: .utf8)
        pidFile = file

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reap() }
        }
        source.resume()
        self.source = source
        reap()  // a guard that died before the source was set up
    }

    /// Asks the guard to stop the service (it runs the M9 sequence). `true` when it ended
    /// within `timeout`.
    func stop(timeout: Duration) async -> Bool {
        guard isRunning else { return true }
        stopRequested = true
        kill(pid, SIGTERM)
        return await exitStatus.value(timeout: timeout) != nil
    }

    /// The last resort when the stop budget is spent: SIGKILL to the guard's whole group.
    func forceKill() async {
        guard isRunning else { return }
        stopRequested = true
        killpg(pid, SIGKILL)
        _ = await exitStatus.value(timeout: .seconds(1))
    }

    private func reap() {
        guard pid > 0, !exitStatus.isSet, let status = ExitStatus.reap(pid, block: false) else { return }
        source?.cancel()
        source = nil
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        exitStatus.fulfill(status)
        if !stopRequested { onUnexpectedExit?(status) }
    }
}
