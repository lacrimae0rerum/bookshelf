import Darwin
import Foundation

/// `Bookshelf --guard <app-pid> -- <command…>` (M8, §19). The guard leads a process group,
/// runs the command in it, and watches the app with kqueue. When the app exits, however it
/// exits (⌘Q, a crash, Force Quit), or when the app sends the guard SIGTERM, the guard
/// stops the command with the M9 sequence and clears the group. When the command exits by
/// itself, the guard clears the group and exits with the command's status.
enum Guard {
    static let flag = "--guard"

    struct Arguments: Equatable {
        let appPID: pid_t
        let command: [String]
    }

    /// `["--guard", "<pid>", "--", "<command>", …]` → arguments; `nil` when malformed.
    static func parse(_ args: [String]) -> Arguments? {
        guard args.count >= 4, args[0] == flag, let pid = pid_t(args[1]), pid > 1, args[2] == "--" else { return nil }
        return Arguments(appPID: pid, command: Array(args[3...]))
    }

    /// The guard's entry point (`args` without the executable).
    static func main(_ args: [String]) -> Never {
        guard let arguments = parse(args), arguments.command[0].hasPrefix("/") else {
            say("usage: Bookshelf --guard <app-pid> -- </absolute/command> [args…]")
            exit(64)
        }
        if getpgrp() != getpid() { setpgid(0, 0) }  // the app spawns it as a leader already
        let group = getpgrp()
        let queue = ExitQueue()
        for signal in [SIGTERM, SIGINT, SIGHUP] { queue.watch(signal: signal) }

        let child: pid_t
        do {
            child = try Spawn.run(arguments.command, env: ProcessInfo.processInfo.environment)
        } catch {
            say("\(error)")
            exit(127)
        }
        say("started \(child) in group \(group) for app \(arguments.appPID): \(arguments.command.joined(separator: " "))")

        let outcome = GuardLoop.run(appPID: arguments.appPID, child: child, group: group, queue: queue, log: say)
        let others = GroupCleanup.killOthers(in: group)
        switch outcome {
        case .childExited(let status):
            say("command exited with status \(status)" + (others > 0 ? "; killed \(others) left in the group" : ""))
            exit(status)
        case .stopped(let step, let reason):
            say("stopped (\(reason)) at \(step.rawValue)" + (others > 0 ? "; killed \(others) left in the group" : ""))
            exit(0)
        }
    }

    /// One line on stderr, which the app points at the service's log.
    static func say(_ message: String) {
        FileHandle.standardError.write(Data("\(Log.timestamp()) [guard \(getpid())] \(message)\n".utf8))
    }
}

/// The guard's event loop, apart from the process-wide setup so tests can drive it.
enum GuardLoop {
    enum Outcome: Equatable {
        case childExited(Int32)
        case stopped(StopStep, reason: String)
    }

    static func run(
        appPID: pid_t,
        child: pid_t,
        group: pid_t,
        queue: ExitQueue,
        timings: StopTimings = .standard,
        log: (String) -> Void
    ) -> Outcome {
        guard queue.watch(pid: child) else {
            return .childExited(ExitStatus.reap(child, block: true) ?? -1)
        }
        // Register first, then look: an app that died before the registration is caught here.
        let appAlive = queue.watch(pid: appPID) && kill(appPID, 0) == 0
        if !appAlive { return stop("app \(appPID) is gone") }

        while true {
            switch queue.next(timeout: nil) {
            case .exited(child): return .childExited(ExitStatus.reap(child, block: true) ?? -1)
            case .exited(appPID): return stop("app \(appPID) exited")
            case .signal(let number): return stop("received signal \(number)")
            default: continue
            }
        }

        func stop(_ reason: String) -> Outcome {
            log("stopping: \(reason)")
            let step = StopSequence.run(
                child: child, group: group, timings: timings, waitExit: waitChild,
                killGroup: {  // not killpg: the guard is in the group and must live to log
                    kill(child, SIGKILL)
                    GroupCleanup.killOthers(in: group)
                    _ = ExitStatus.reap(child, block: true)
                },
                log: log
            )
            return .stopped(step, reason: reason)
        }

        func waitChild(_ timeout: Duration) -> Bool {
            let deadline = ContinuousClock.now + timeout
            while true {
                let left = deadline - ContinuousClock.now
                guard left > .zero, let event = queue.next(timeout: left) else {
                    return ExitStatus.reap(child, block: false) != nil
                }
                if event == .exited(child) {
                    _ = ExitStatus.reap(child, block: true)
                    return true
                }
            }
        }
    }
}

/// Whatever the command left in the guard's group: `node` workers, a `uv` child.
enum GroupCleanup {
    /// SIGKILL to every member of `group` but the caller; returns how many there were.
    @discardableResult
    static func killOthers(in group: pid_t) -> Int {
        var killed = Set<pid_t>()
        for _ in 0..<3 {  // a member may fork while we look; a zombie stays listed until reaped
            let others = members(of: group).filter { $0 != getpid() && !killed.contains($0) }
            if others.isEmpty { break }
            for pid in others where kill(pid, SIGKILL) == 0 { killed.insert(pid) }
            usleep(10_000)
        }
        return killed.count
    }

    static func members(of group: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        // Unlike `proc_listpids`, this one returns a count of pids, not of bytes.
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listpgrppids(group, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }
}
