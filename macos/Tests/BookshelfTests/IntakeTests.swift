import Foundation
import Testing
@testable import Bookshelf

/// Intake end to end, with a stub in place of the API (§13). The queue: IntakeQueueTests.
@MainActor
struct IntakeTests {
    @Test func a202OpensTheNewDocumentAndKeepsTheCopy() async throws {
        let (source, library) = try sourceAndLibrary("Meadows Systems.pdf")
        let api = StubAPI([addedReply])
        let (intake, presenter) = makeIntake(api, library: library)
        await intake.receiveAndWait([source])
        #expect(api.bodies == [["path": "inbox/2026-11/Meadows Systems.pdf"]])
        #expect(exists(library, "inbox/2026-11/Meadows Systems.pdf"))
        #expect(presenter.reports == [IntakeReport(pageToOpen: "/documents/meadows-systems", notice: nil)])
    }

    @Test func a409DeletesTheCopyAndOffersTheExistingDocument() async throws {
        let (source, library) = try sourceAndLibrary("Meadows Systems.pdf")
        let (intake, presenter) = makeIntake(StubAPI([duplicateReply]), library: library)
        await intake.receiveAndWait([source])
        #expect(!exists(library, "inbox/2026-11/Meadows Systems.pdf"))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let report = try #require(presenter.reports.first)
        #expect(report.pageToOpen == nil)
        #expect(report.notice?.title == "“Meadows Systems.pdf” is already on the shelf.")
        #expect(report.notice?.existing == meadows)
    }

    @Test func anErrorDeletesTheCopyAndSaysWhatTheAPISaid() async throws {
        let (source, library) = try sourceAndLibrary("x.pdf")
        let refused = HTTPReply(status: 400, body: Data(#"{"error":{"code":"invalid_input","message":"Not a regular file: inbox/2026-11/x.pdf","details":[]}}"#.utf8))
        let (intake, presenter) = makeIntake(StubAPI([refused]), library: library)
        await intake.receiveAndWait([source])
        #expect(!exists(library, "inbox/2026-11/x.pdf"))
        #expect(presenter.reports.first?.notice == IntakeNotice(title: "“x.pdf” was not added.", detail: "Not a regular file: inbox/2026-11/x.pdf", existing: nil))
    }

    /// The API may have taken the file before its answer was lost: deleting the copy could
    /// leave a document without its file. If it was not taken, *Add a book* lists it.
    @Test func noAnswerKeepsTheCopyAndSaysWhere() async throws {
        let (source, library) = try sourceAndLibrary("x.epub")
        let (intake, presenter) = makeIntake(StubAPI([nil]), library: library)
        await intake.receiveAndWait([source])
        #expect(exists(library, "inbox/2026-11/x.epub"))
        #expect(presenter.reports.first?.notice?.detail == "The Bookshelf API did not answer. The copy stays at library/inbox/2026-11/x.epub: if it is not on the shelf, add it from Add a book.")
    }

    /// The proxy's `upstream_unavailable` cannot tell a refused connection from a cut one.
    @Test func theProxysUpstreamUnavailableKeepsTheCopy() async throws {
        let (source, library) = try sourceAndLibrary("x.pdf")
        let unreachable = HTTPReply(status: 502, body: Data(#"{"error":{"code":"upstream_unavailable","message":"The Bookshelf API could not be reached.","details":[]}}"#.utf8))
        let (intake, presenter) = makeIntake(StubAPI([unreachable]), library: library)
        await intake.receiveAndWait([source])
        #expect(exists(library, "inbox/2026-11/x.pdf"))
        #expect(presenter.reports.first?.notice?.title == "“x.pdf” may not have been added.")
    }

    @Test func anUnsupportedFileIsNeitherCopiedNorSent() async throws {
        let (source, library) = try sourceAndLibrary("notes.docx")
        let api = StubAPI([])
        let (intake, presenter) = makeIntake(api, library: library)
        await intake.receiveAndWait([source])
        #expect(api.bodies.isEmpty)
        #expect(!exists(library, "inbox"))
        #expect(presenter.reports.first?.notice?.title == "“notes.docx” was not added.")
    }

    /// A library it cannot write to (or a full disk): told, and nothing is sent.
    @Test func aCopyThatFailsIsToldAndNothingIsSent() async throws {
        let (source, library) = try sourceAndLibrary("x.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path) }
        let api = StubAPI([addedReply])
        let (intake, presenter) = makeIntake(api, library: library)
        await intake.receiveAndWait([source])
        #expect(api.bodies.isEmpty)
        let notice = try #require(presenter.reports.first?.notice)
        #expect(notice.title == "“x.pdf” was not added.")
        #expect(notice.detail.hasPrefix("It could not be copied into the library: "))
    }

    /// One new document opens its page; several open the library, where they all show.
    @Test func severalNewDocumentsOpenTheLibrary() async throws {
        let (first, library) = try sourceAndLibrary("a.pdf")
        let second = try sibling(first, "b.md", contents: "# B")
        let (intake, presenter) = makeIntake(StubAPI([addedReply, addedReply]), library: library)
        await intake.receiveAndWait([first, second])
        #expect(presenter.reports == [IntakeReport(pageToOpen: "/library", notice: nil)])
    }

    @Test func aBatchOpensWhatWasAddedAndTellsTheRest() async throws {
        let (first, library) = try sourceAndLibrary("new.pdf")
        let second = try sibling(first, "old.pdf")
        let (intake, presenter) = makeIntake(StubAPI([addedReply, duplicateReply]), library: library)
        await intake.receiveAndWait([first, second])
        let report = try #require(presenter.reports.first)
        #expect(report.pageToOpen == "/documents/meadows-systems")
        #expect(report.notice?.existing == meadows)
        #expect(exists(library, "inbox/2026-11/new.pdf") && !exists(library, "inbox/2026-11/old.pdf"))
    }

    @Test func severalProblemsAreToldInOneNotice() async throws {
        let (first, library) = try sourceAndLibrary("notes.docx")
        let second = try sibling(first, "x.pdf")
        let (intake, presenter) = makeIntake(StubAPI([nil]), library: library)
        await intake.receiveAndWait([first, second])
        let notice = try #require(presenter.reports.first?.notice)
        #expect(notice.title == "2 files were not added.")
        #expect(notice.detail.split(separator: "\n").count == 2)
        #expect(notice.existing == nil)
    }

    @Test func aWebArticleIsPostedAndOpened() async throws {
        let api = StubAPI([addedReply])
        let (intake, presenter) = makeIntake(api, library: try temporaryDirectory())
        await intake.addWebArticle(URL(string: "https://example.com/essay")!)
        #expect(api.bodies == [["url": "https://example.com/essay"]])
        #expect(presenter.reports.first?.pageToOpen == "/documents/meadows-systems")
    }

    @Test func aWebArticleAlreadyOnTheShelfOffersIt() async throws {
        let (intake, presenter) = makeIntake(StubAPI([duplicateReply]), library: try temporaryDirectory())
        await intake.addWebArticle(URL(string: "https://example.com/essay")!)
        #expect(presenter.reports.first?.notice?.title == "“https://example.com/essay” is already on the shelf.")
        #expect(presenter.reports.first?.notice?.existing == meadows)
    }

    // MARK: The log (app.log and the unified log, both public)

    /// A line names the file and its copy in the library, never the folders they are in.
    @Test func theLogNamesFilesButNotTheirFolders() async throws {
        let (source, library) = try sourceAndLibrary("Meadows Systems.pdf")
        let others = [try sibling(source, "notes.docx"), try sibling(source, "old.pdf"), try sibling(source, "lost.pdf")]
        let log = LogRecorder()
        let (intake, _) = makeIntake(StubAPI([addedReply, duplicateReply, nil]), library: library, log: log)
        await intake.receiveAndWait([source] + others)
        #expect(log.lines.contains("intake: Meadows Systems.pdf → library/inbox/2026-11/Meadows Systems.pdf: added as meadows-systems"))
        #expect(log.lines.count >= 4)
        let folders = [source.deletingLastPathComponent().path, library.path, FileManager.default.homeDirectoryForCurrentUser.path]
        for line in log.lines {
            #expect(!folders.contains { line.contains($0) }, "\(line)")
        }
    }

    @Test func aFailedCopyIsLoggedWithoutItsFolders() async throws {
        let (source, library) = try sourceAndLibrary("x.pdf")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path) }
        let log = LogRecorder()
        let (intake, _) = makeIntake(StubAPI([]), library: library, log: log)
        await intake.receiveAndWait([source])
        let line = try #require(log.lines.first { $0.contains("copy failed") })
        #expect(line.hasPrefix("intake: x.pdf: copy failed"))
        #expect(!line.contains(source.deletingLastPathComponent().path) && !line.contains(library.path))
    }

    /// The path and query of a page can hold what a person would not want logged.
    @Test func theLogNamesAWebArticleBySchemeAndHostOnly() async throws {
        let log = LogRecorder()
        let (intake, _) = makeIntake(StubAPI([addedReply]), library: try temporaryDirectory(), log: log)
        await intake.addWebArticle(URL(string: "https://example.com/private/essay?token=s3cret#frag")!)
        #expect(log.lines == ["intake: web article from https://example.com: added as meadows-systems"])
    }
}
