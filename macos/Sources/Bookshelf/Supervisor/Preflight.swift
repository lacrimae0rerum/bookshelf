import Darwin
import Foundation

/// What every start needs: the repo, the tools and the environment (§3, §5).
struct LaunchContext: Sendable {
    let repo: Repository
    let tools: Tools
    let environment: [String: String]
}

/// Why a start stopped, in one sentence, with the log that says more (§17).
struct StartFailure: Error, Sendable, Equatable {
    /// `nil`: before any service (repo, PATH, tools, ports).
    let step: Supervisor.Step?
    let message: String
    let log: URL?
}

/// The checks before anything starts: repo, PATH, tools, stale guards, ports.
enum Preflight {
    @MainActor
    static func run(
        paths: AppPaths,
        preferences: Preferences,
        executable: String,
        bundle: Bundle = .main,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Result<LaunchContext, StartFailure> {
        let appLog = paths.log(.app)
        guard let configured = preferences.repositoryPath ?? bundle.object(forInfoDictionaryKey: "BookshelfRepositoryPath") as? String else {
            return .failure(StartFailure(step: nil, message: "This build does not say where the Bookshelf folder is. Build the app with macos/scripts/build-app.sh.", log: appLog))
        }
        guard let repo = Repository.at(configured) else {
            return .failure(StartFailure(step: nil, message: "The Bookshelf folder was not found at \(configured).", log: appLog))
        }

        guard let path = await loginPath(base: base, state: paths.state) else {
            return .failure(StartFailure(step: nil, message: "The login shell's PATH could not be read, and no earlier copy is saved.", log: appLog))
        }

        let tools: Tools
        do {
            tools = try ToolResolver.resolve(path: path, claudeOverride: preferences.claudeBinary)
        } catch {
            return .failure(StartFailure(step: nil, message: error.description, log: appLog))
        }
        Log.info("tools: uv \(tools.uv), node \(tools.node), pnpm \(tools.pnpm)", .supervisor)
        if let claude = tools.claude {
            Log.info("claude: \(claude)", .supervisor)
        } else {
            Log.error("claude: not found\(preferences.claudeBinary.map { " (override \($0) is not executable)" } ?? ""); model jobs will fail", .supervisor)
        }

        var extra: [String: String] = [:]
        if let claude = tools.claude { extra["BOOKSHELF_CLAUDE_BIN"] = claude }
        let environment = ChildEnvironment.build(base: base, path: path, extra: extra)

        await stopStaleGuards(paths: paths, executable: executable)
        for (port, name) in [(Loopback.apiPort, "API"), (Loopback.webPort, "web server")] {
            guard await !Ports.waitFree(port, timeout: .seconds(1)) else { continue }
            let owners = await Ports.owners(of: port)
            let who = owners.isEmpty ? "another program" : owners.map(\.description).joined(separator: ", ")
            return .failure(StartFailure(step: nil, message: "Port \(port), the \(name)'s, is in use by \(who). Quit it, then Retry.", log: appLog))
        }
        return .success(LaunchContext(repo: repo, tools: tools, environment: environment))
    }

    /// The login shell's PATH, saved in `state.json`; the saved copy when the shell fails.
    private static func loginPath(base: [String: String], state url: URL) async -> String? {
        var state = StateStore.load(url)
        do {
            let path = try await ShellPath.capture(base: base)
            state.path = path
            state.pathCapturedAt = Date()
            try? StateStore.save(state, to: url)
            Log.info("PATH: \(path)", .supervisor)
            return path
        } catch {
            Log.error("PATH capture failed (\(error)); using the copy from \(state.pathCapturedAt.map(Log.timestamp) ?? "never")", .supervisor)
            return state.path
        }
    }

    /// A guard from an earlier run that is still alive (it may be finishing its stop) is
    /// given the stop budget, then its group is killed. Other pids in `pids/` are not ours.
    private static func stopStaleGuards(paths: AppPaths, executable: String) async {
        let ours = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        for service in ServiceID.allCases {
            let file = paths.pidFile(service)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            defer { try? FileManager.default.removeItem(at: file) }
            guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
                  kill(pid, 0) == 0, executablePath(of: pid) == ours else { continue }
            Log.info("the \(service.rawValue) guard of an earlier run is alive (pid \(pid)): stopping it", .supervisor)
            kill(pid, SIGTERM)
            let deadline = ContinuousClock.now + .seconds(7)
            while kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if kill(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(nulTerminated: buffer)).resolvingSymlinksInPath().path
    }
}
