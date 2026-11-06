/// Reads the job queue now and then for the menu bar icon (§10), only while the services are
/// ready: at once when they become ready, then at `interval`'s pace. Each read is a line in
/// api.log, so never faster than every 5 s. A `Task` loop: it holds nothing open at quit.
@MainActor
final class QueuePoll {
    nonisolated static let busy: Duration = .seconds(5)
    nonisolated static let quiet: Duration = .seconds(30)

    private let phase: () -> Supervisor.Phase
    private let read: @MainActor () async -> QueueSummary?
    private let deliver: (QueueSummary?) -> Void
    private let sleep: @MainActor (Duration) async throws -> Void
    /// The running loop, if any.
    private(set) var task: Task<Void, Never>?

    init(
        phase: @escaping () -> Supervisor.Phase,
        read: @escaping @MainActor () async -> QueueSummary?,
        deliver: @escaping (QueueSummary?) -> Void,
        sleep: @escaping @MainActor (Duration) async throws -> Void
    ) {
        self.phase = phase
        self.read = read
        self.deliver = deliver
        self.sleep = sleep
    }

    /// The wait before the next read; `nil` when the services are not ready (no poll). Every
    /// 5 s while jobs run or wait in a queue that is not paused; every 30 s otherwise, and
    /// when the queue did not answer.
    nonisolated static func interval(phase: Supervisor.Phase, queue: QueueSummary?) -> Duration? {
        guard phase == .ready else { return nil }
        guard let queue, !queue.paused, queue.running + queue.queued > 0 else { return quiet }
        return busy
    }

    /// Call on every supervisor change: starts the loop when the services are ready, stops
    /// it when they are not.
    func sync() {
        guard phase() == .ready else { return stop() }
        if task == nil { task = Task { await poll() } }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The real read: `GET /jobs/queue` through the web's proxy, 1 s at most.
    static func readQueue() async -> QueueSummary? {
        await JobsAPI.queue(timeout: 1)
    }

    /// The real clock.
    static func wait(_ interval: Duration) async throws {
        try await Task.sleep(for: interval)
    }

    private func poll() async {
        while true {
            let queue = await read()
            guard !Task.isCancelled else { return }  // stopped meanwhile: `task` may be a newer loop
            guard let interval = Self.interval(phase: phase(), queue: queue) else {
                task = nil  // the services left `.ready` before any `sync` saw it
                return
            }
            deliver(queue)
            do { try await sleep(interval) } catch { return }  // cancelled
        }
    }
}
