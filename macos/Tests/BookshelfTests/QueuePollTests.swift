import Testing
@testable import Bookshelf

/// The menu bar icon reads the job queue only while the services are ready, and never faster
/// than every 5 s: each read is a line in api.log (docs/MACOS_APP.md §10).
struct QueuePollPaceTests {
    @Test func pollsOnlyWhileTheServicesAreReady() {
        for phase in [Supervisor.Phase.idle, .starting, .stopping, .failed] {
            #expect(QueuePoll.interval(phase: phase, queue: jobQueue(running: 1)) == nil, "\(phase)")
        }
    }

    @Test func everyFiveSecondsWhileJobsRunOrWait() {
        #expect(QueuePoll.interval(phase: .ready, queue: jobQueue(running: 1)) == .seconds(5))
        #expect(QueuePoll.interval(phase: .ready, queue: jobQueue(queued: 2)) == .seconds(5))
    }

    /// An idle or paused queue, or one not read (no answer): every 30 s.
    @Test func everyThirtySecondsOtherwise() {
        #expect(QueuePoll.interval(phase: .ready, queue: jobQueue()) == .seconds(30))
        #expect(QueuePoll.interval(phase: .ready, queue: jobQueue(running: 1, queued: 3, paused: true)) == .seconds(30))
        #expect(QueuePoll.interval(phase: .ready, queue: nil) == .seconds(30))
    }
}

/// The poll's loop, with a fake queue and a fake clock: no network, no real waiting. A broken
/// stop fails in 2 s (`FakeQueue.missedStops`); the time limit is the last resort.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct QueuePollTests {
    let fake = FakeQueue()

    @Test func readsAtOnceWhenReadyThenWaitsTheInterval() async {
        fake.answer = jobQueue(running: 2)
        fake.poll.sync()
        #expect(await until { fake.sleeps.count == 1 })
        #expect(fake.reads == 1)
        #expect(fake.delivered == [jobQueue(running: 2)])
        #expect(fake.sleeps == [.seconds(5)])
        await fake.stop()
    }

    @Test func neverPollsWhenNotReady() async {
        for phase in [Supervisor.Phase.idle, .starting, .stopping, .failed] {
            fake.phase = phase
            fake.poll.sync()
            #expect(fake.poll.task == nil, "\(phase)")
        }
        await Task.yield()
        #expect(fake.reads == 0)
    }

    @Test func oneLoopAtATime() async {
        fake.poll.sync()
        let first = fake.poll.task
        fake.poll.sync()
        #expect(fake.poll.task == first)
        #expect(await until { fake.sleeps.count == 1 })
        #expect(fake.reads == 1)
        await fake.stop()
    }

    @Test func stopsWhenThePhaseLeavesReady() async {
        fake.poll.sync()
        #expect(await until { fake.sleeps.count == 1 })
        let running = fake.poll.task
        fake.phase = .stopping
        fake.poll.sync()
        #expect(fake.poll.task == nil)
        await running?.value  // the cancelled wait ends the loop
        #expect(fake.missedStops == 0)
        #expect(fake.reads == 1)
        #expect(fake.sleeps.count == 1)
    }

    /// A stopped loop's read that answers late changes nothing, even when the services are
    /// ready again and a newer loop runs: one loop, one delivery.
    @Test func aReadThatOutlivesTheStopIsDropped() async {
        let gate = Eventual<Bool>()
        fake.gate = gate
        fake.poll.sync()
        #expect(await until { fake.reads == 1 })
        let stopped = fake.poll.task
        fake.phase = .stopping
        fake.poll.sync()
        fake.phase = .ready
        fake.poll.sync()
        let newer = fake.poll.task
        #expect(await until { fake.sleeps.count == 1 })
        gate.fulfill(true)
        await stopped?.value
        #expect(fake.delivered.count == 1)
        #expect(fake.sleeps.count == 1)
        #expect(fake.poll.task == newer)
        await fake.stop()
    }

    /// The services left `.ready` with no `sync` yet: the loop ends by itself, and the next
    /// `sync` at `.ready` starts a new one.
    @Test func endsByItselfWhenTheServicesLeftReadyUnseen() async {
        fake.onRead = { fake.phase = .starting }
        fake.poll.sync()
        await fake.poll.task?.value
        #expect(fake.poll.task == nil)
        #expect(fake.delivered.isEmpty)
        fake.onRead = nil
        fake.phase = .ready
        fake.poll.sync()
        #expect(await until { fake.sleeps.count == 1 })
        #expect(fake.reads == 2)
        await fake.stop()
    }
}

/// A job queue for `QueuePoll`: answers with `answer`, the next read after `gate` when set.
/// Its waits record the interval and last until cancelled, or 2 s: a wait that runs out
/// counts as a missed stop and ends the loop, so a broken stop fails instead of hanging.
@MainActor
final class FakeQueue {
    var phase: Supervisor.Phase = .ready
    var answer: QueueSummary? = jobQueue()
    var gate: Eventual<Bool>?
    var onRead: (() -> Void)?
    private(set) var reads = 0
    private(set) var delivered: [QueueSummary?] = []
    private(set) var sleeps: [Duration] = []
    private(set) var missedStops = 0

    private(set) var poll: QueuePoll!

    /// Weak references: a loop that a broken stop leaves running outlives the test, and must
    /// not crash the test process when it wakes.
    init() {
        poll = QueuePoll(
            phase: { [weak self] in self?.phase ?? .idle },
            read: { [weak self] in await self?.read() },
            deliver: { [weak self] in self?.delivered.append($0) },
            sleep: { [weak self] interval in try await self?.sleep(interval) }
        )
    }

    private func read() async -> QueueSummary? {
        reads += 1
        if let gate {  // only this read waits
            self.gate = nil
            _ = await gate.value()
        }
        onRead?()
        return answer
    }

    private func sleep(_ interval: Duration) async throws {
        sleeps.append(interval)
        try await Task.sleep(for: .seconds(2))
        missedStops += 1
        throw CancellationError()
    }

    /// Stops the poll and waits for its loop to end; the stop must have cancelled the wait.
    func stop() async {
        let running = poll.task
        poll.stop()
        await running?.value
        #expect(missedStops == 0, "the poll's wait was not cancelled")
    }
}
