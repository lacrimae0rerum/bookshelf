import Foundation
import Testing
@testable import Bookshelf

/// Intake's queue: files wait for the services, go in batch by batch, and never overlap.
@MainActor
struct IntakeQueueTests {
    /// A file opened from the Dock while the services start waits, uncopied, until ready;
    /// `resumeIfReady` (called on every supervisor change) then starts the batch.
    @Test func filesWaitUntilTheServicesAreReady() async throws {
        let (source, library) = try sourceAndLibrary("early.pdf")
        let api = StubAPI([addedReply])
        let ready = ReadyFlag()
        let (intake, presenter) = makeIntake(api, ready: ready)
        #expect(intake.receive([source]) == nil)
        #expect(intake.resumeIfReady() == nil)
        #expect(intake.pending == [source] && api.bodies.isEmpty && presenter.reports.isEmpty)
        #expect(!exists(library, "inbox"))
        ready.library = library
        await intake.resumeIfReady()?.value
        #expect(api.paths == ["inbox/2026-11/early.pdf"])
        #expect(intake.pending.isEmpty)
        #expect(presenter.reports.first?.pageToOpen == "/documents/meadows-systems")
    }

    @Test func nothingWaitingStartsNothing() {
        let (intake, _) = makeIntake(StubAPI([]), library: URL(fileURLWithPath: "/nonexistent"))
        #expect(intake.resumeIfReady() == nil)
    }

    /// Files dropped while a notice is open join the next batch: one batch at a time, and
    /// one notice at a time.
    @Test func filesThatArriveDuringANoticeMakeTheNextBatch() async throws {
        let (first, library) = try sourceAndLibrary("first.pdf")
        let second = try sibling(first, "second.pdf")
        let api = StubAPI([addedReply, addedReply])
        let presenter = HoldingPresenter()
        let intake = Intake(send: api.send, readyLibrary: { library }, now: { november4 }, calendar: utc, log: LogRecorder().sink)
        intake.presenter = presenter
        let running = intake.receive([first])
        #expect(await until { presenter.isHolding })
        #expect(intake.receive([second]) == nil)  // the running batch loop takes it
        #expect(api.paths == ["inbox/2026-11/first.pdf"])
        presenter.letGo()
        await running?.value
        #expect(api.paths == ["inbox/2026-11/first.pdf", "inbox/2026-11/second.pdf"])
        #expect(presenter.reports.count == 2 && presenter.mostOpenAtOnce == 1)
        #expect(intake.pending.isEmpty)
    }

    /// The services stop mid-batch (a restart): what was not copied yet waits for them.
    @Test func filesLeftWhenTheServicesStopMidBatchWait() async throws {
        let (first, library) = try sourceAndLibrary("first.pdf")
        let second = try sibling(first, "second.pdf")
        let ready = ReadyFlag()
        ready.library = library
        let api = StubAPI([addedReply, addedReply])
        api.onSend = { ready.library = nil }
        let (intake, presenter) = makeIntake(api, ready: ready)
        await intake.receiveAndWait([first, second])
        #expect(api.paths == ["inbox/2026-11/first.pdf"])
        #expect(intake.pending == [second])
        #expect(!exists(library, "inbox/2026-11/second.pdf"))
        #expect(presenter.reports == [IntakeReport(pageToOpen: "/documents/meadows-systems", notice: nil)])
        api.onSend = nil
        ready.library = library
        await intake.resumeIfReady()?.value
        #expect(api.paths == ["inbox/2026-11/first.pdf", "inbox/2026-11/second.pdf"])
        #expect(intake.pending.isEmpty)
    }
}
