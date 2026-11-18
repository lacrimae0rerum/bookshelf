import Testing
@testable import Bookshelf

struct JobsInterruptionTests {
    private func queue(running: Int, queued: Int = 0, paused: Bool = false) -> QueueSummary {
        QueueSummary(queued: queued, running: running, paused: paused, pausedReason: nil)
    }

    @Test func asksOnlyWhileReadyAndAJobRuns() {
        #expect(JobsInterruption.mustAsk(phase: .ready, queue: queue(running: 1)))
        #expect(!JobsInterruption.mustAsk(phase: .ready, queue: queue(running: 0, queued: 4)))
        #expect(!JobsInterruption.mustAsk(phase: .ready, queue: nil))
        #expect(!JobsInterruption.mustAsk(phase: .starting, queue: queue(running: 2)))
        #expect(!JobsInterruption.mustAsk(phase: .failed, queue: queue(running: 2)))
    }

    @Test func namesTheActionAndTheJobs() {
        #expect(JobsInterruption.restart.question(running: 1) == "1 job is running. Restart anyway?")
        #expect(JobsInterruption.restart.question(running: 3) == "3 jobs are running. Restart anyway?")
        #expect(JobsInterruption.quit.question(running: 2) == "2 jobs are running. Quit anyway?")
        #expect(JobsInterruption.restart.button == "Restart")
    }

    @Test func onlyTheQuitQuestionCanBeTurnedOff() {
        #expect(JobsInterruption.quit.offersSuppression)
        #expect(!JobsInterruption.restart.offersSuppression)
    }
}
