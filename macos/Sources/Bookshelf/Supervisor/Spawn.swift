import Darwin

/// `posix_spawn` with a clean slate: default signal handlers, an empty signal mask, stdin
/// from `/dev/null` and no inherited descriptors but stdout and stderr. Foundation's
/// `Process` cannot put a child in a process group of its own; this can (M8).
enum Spawn {
    enum Output: Sendable {
        /// Keep the caller's stdout and stderr (the guard's: the service log).
        case inherit
        /// Append both to this file.
        case file(String)
    }

    struct Failure: Error, CustomStringConvertible {
        let path: String
        let code: Int32
        var description: String { "cannot start \(path): \(String(cString: strerror(code)))" }
    }

    /// Starts `argv` (`argv[0]` absolute) and returns its pid. `newGroup`: the child leads a
    /// process group of its own, so a signal to the caller's group never reaches it.
    static func run(
        _ argv: [String],
        env: [String: String],
        cwd: String? = nil,
        output: Output = .inherit,
        newGroup: Bool = false
    ) throws(Failure) -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        if newGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_USER_INITIATED)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        switch output {
        case .inherit:
            posix_spawn_file_actions_addinherit_np(&actions, 1)
            posix_spawn_file_actions_addinherit_np(&actions, 2)
        case .file(let path):
            posix_spawn_file_actions_addopen(&actions, 1, path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        }
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }

        var pid: pid_t = 0
        let environment = env.map { "\($0.key)=\($0.value)" }
        let code = withCStrings(argv) { cArgv in
            withCStrings(environment) { cEnv in
                posix_spawn(&pid, argv[0], &actions, &attributes, cArgv, cEnv)
            }
        }
        guard code == 0 else { throw Failure(path: argv[0], code: code) }
        return pid
    }

    private static func withCStrings<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Exit statuses from `waitpid`.
enum ExitStatus {
    /// The exit code, or 128 + the signal number for a process a signal ended (shell style).
    static func decode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Reaps `pid`; `nil` while it is still running (`block: false`) or when it is not ours.
    static func reap(_ pid: pid_t, block: Bool) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, block ? 0 : WNOHANG)
            if result == pid { return decode(status) }
            if result == -1 && errno == EINTR { continue }
            return nil
        }
    }
}
