import Foundation

/// A value set once and awaited by anyone, with an optional timeout: a process's exit
/// status, mostly.
final class Eventual<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    var isSet: Bool { lock.withLock { stored != nil } }

    /// Sets the value and wakes every waiter. Only the first call counts.
    func fulfill(_ value: Value) {
        let woken: [CheckedContinuation<Value?, Never>] = lock.withLock {
            guard stored == nil else { return [] }
            stored = value
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in woken { waiter.resume(returning: value) }
    }

    /// The value, or `nil` when `timeout` passes first (`nil` timeout: wait for ever).
    func value(timeout: Duration? = nil) async -> Value? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let ready: Value? = lock.withLock {
                if let stored { return stored }
                waiters[id] = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            } else if let timeout {
                Task.detached { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expire(id)
                }
            }
        }
    }

    private func expire(_ id: UUID) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resume(returning: nil)
    }
}
