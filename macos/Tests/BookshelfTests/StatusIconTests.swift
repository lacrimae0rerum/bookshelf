import Testing
@testable import Bookshelf

/// The menu bar icon (docs/MACOS_APP.md §10): the state by shape, never colour, and in words.
struct StatusIconTests {
    @Test func eachStateHasItsSymbol() {
        let expected: [(Supervisor.Phase, QueueSummary?, String)] = [
            (.starting, nil, "hourglass"),
            (.stopping, nil, "hourglass"),
            (.idle, nil, "hourglass"),
            (.ready, jobQueue(), "books.vertical"),
            (.ready, jobQueue(running: 2, queued: 5), "books.vertical.fill"),
            (.ready, jobQueue(queued: 3, paused: true), "pause.circle"),
            (.failed, nil, "exclamationmark.triangle.fill"),
        ]
        for (phase, queue, symbol) in expected {
            #expect(StatusIcon(phase: phase, queue: queue).symbolName == symbol, "\(phase) \(String(describing: queue))")
        }
    }

    /// Failed > starting or stopping > paused > running > ready.
    @Test func theQueueCountsOnlyWhenTheServicesAreReady() {
        let busy = jobQueue(running: 2, paused: true)
        #expect(StatusIcon(phase: .failed, queue: busy) == .failed)
        #expect(StatusIcon(phase: .starting, queue: busy) == .starting)
        #expect(StatusIcon(phase: .stopping, queue: busy) == .stopping)
    }

    @Test func aPausedQueueWinsOverRunningJobs() {
        #expect(StatusIcon(phase: .ready, queue: jobQueue(running: 1, paused: true)) == .paused)
    }

    @Test func readyBeforeTheQueueIsReadShowsTheBooks() {
        #expect(StatusIcon(phase: .ready, queue: nil) == .ready)
        #expect(StatusIcon(phase: .ready, queue: nil).symbolName == "books.vertical")
    }

    /// Jobs waiting with none running yet: nothing runs, so the books stay empty.
    @Test func queuedJobsAloneAreNotRunning() {
        #expect(StatusIcon(phase: .ready, queue: jobQueue(queued: 4)) == .ready)
    }

    @Test func saysTheStateInWords() {
        let expected: [(StatusIcon, String)] = [
            (.starting, "Bookshelf — starting…"),
            (.stopping, "Bookshelf — stopping…"),
            (.notRunning, "Bookshelf — not running"),
            (.ready, "Bookshelf — ready"),
            (.running(1), "Bookshelf — ready, 1 job running"),
            (.running(2), "Bookshelf — ready, 2 jobs running"),
            (.paused, "Bookshelf — job queue paused"),
            (.failed, "Bookshelf — a service failed"),
        ]
        for (icon, words) in expected {
            #expect(icon.words == words)
        }
    }
}
