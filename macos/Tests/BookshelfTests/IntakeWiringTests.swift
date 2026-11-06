import AppKit
import Testing
@testable import Bookshelf

/// How the app delegate hands files to intake (§9, §13), without running the app: the
/// delegate is built, never launched, so there is no window and the services are idle.
@MainActor
struct IntakeWiringTests {
    let delegate = AppDelegate(smoke: SmokeReport(arguments: [], launched: .now))

    /// AppKit sends the files that open the app before `applicationDidFinishLaunching`: no
    /// window, no services yet. Intake keeps them, and only the file URLs.
    @Test func filesOpenedBeforeTheWindowWaitInIntake() {
        let pdf = URL(fileURLWithPath: "/tmp/Meadows Systems.pdf")
        delegate.application(NSApplication.shared, open: [pdf, URL(string: "https://example.com/a")!])
        #expect(delegate.intake.pending == [pdf])
    }

    /// Every supervisor change resumes intake; once the services are ready, what waited goes in.
    @Test func filesThatWaitedGoInWhenTheSupervisorReportsReady() async throws {
        let (source, library) = try sourceAndLibrary("early.pdf")
        let ready = ReadyFlag()
        let api = StubAPI([addedReply])
        let (intake, presenter) = makeIntake(api, ready: ready)
        delegate.intake = intake
        delegate.application(NSApplication.shared, open: [source])
        #expect(delegate.supervisorChanged() == nil)
        #expect(api.bodies.isEmpty)
        ready.library = library
        await delegate.supervisorChanged()?.value
        #expect(api.paths == ["inbox/2026-11/early.pdf"])
        #expect(presenter.reports.first?.pageToOpen == "/documents/meadows-systems")
    }
}
