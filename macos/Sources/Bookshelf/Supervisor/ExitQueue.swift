import Darwin

/// A kqueue that reports process exits (`EVFILT_PROC`/`NOTE_EXIT`) and signals
/// (`EVFILT_SIGNAL`), through `kevent64`: the guard's whole event loop (§19).
final class ExitQueue {
    enum Event: Equatable {
        case exited(pid_t)
        case signal(Int32)
    }

    private let kq: Int32

    init() {
        kq = kqueue()
    }

    deinit {
        close(kq)
    }

    /// Reports `pid`'s exit. `false` when `pid` is already gone (or exiting).
    func watch(pid: pid_t) -> Bool {
        var change = kevent64_s(
            ident: UInt64(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: 0, ext: (0, 0)
        )
        return kevent64(kq, &change, 1, nil, 0, 0, nil) == 0
    }

    /// Reports `signal` instead of acting on it: its disposition becomes `SIG_IGN`, which
    /// kqueue still records.
    func watch(signal number: Int32) {
        Darwin.signal(number, SIG_IGN)
        var change = kevent64_s(
            ident: UInt64(number), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD),
            fflags: 0, data: 0, udata: 0, ext: (0, 0)
        )
        _ = kevent64(kq, &change, 1, nil, 0, 0, nil)
    }

    /// The next event, or `nil` once `timeout` has passed (`nil` timeout: wait for ever).
    func next(timeout: Duration?) -> Event? {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while true {
            var event = kevent64_s()
            let count: Int32
            if let deadline {
                let left = max(deadline - ContinuousClock.now, .zero).components
                var spec = timespec(tv_sec: Int(left.seconds), tv_nsec: Int(left.attoseconds / 1_000_000_000))
                count = kevent64(kq, nil, 0, &event, 1, 0, &spec)
            } else {
                count = kevent64(kq, nil, 0, &event, 1, 0, nil)
            }
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            switch Int32(event.filter) {
            case EVFILT_PROC: return .exited(pid_t(event.ident))
            case EVFILT_SIGNAL: return .signal(Int32(event.ident))
            default: continue
            }
        }
    }
}
