import Foundation
import Testing
@testable import Bookshelf

/// Which files intake takes, and how it copies them into `library/inbox/<yyyy-mm>/` (§13).
struct IntakeFilesTests {
    @Test func acceptsTheAPIsFileTypesInAnyCase() {
        for name in ["a.pdf", "b.EPUB", "c.Html", "d.htm", "e.MD", "Scan.PDF"] {
            #expect(IntakeFiles.isAccepted(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["f.docx", "g", "h.pdf.zip", "i.txt", "j.markdown", "pdf"] {
            #expect(!IntakeFiles.isAccepted(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func namesTheMonthFolderInTheCalendarsTimeZone() throws {
        #expect(IntakeFiles.monthFolder(for: november4, calendar: utc) == "2026-11")
        // 23:30 UTC on 31 January is already February in Madrid.
        let lateJanuary = try Date("2027-01-31T23:30:00Z", strategy: .iso8601)
        var madrid = utc
        madrid.timeZone = try #require(TimeZone(identifier: "Europe/Madrid"))
        #expect(IntakeFiles.monthFolder(for: lateJanuary, calendar: utc) == "2027-01")
        #expect(IntakeFiles.monthFolder(for: lateJanuary, calendar: madrid) == "2027-02")
    }

    @Test func aClashAddsANumberBeforeTheExtension() {
        #expect(IntakeFiles.candidateName("Report.PDF", attempt: 1) == "Report.PDF")
        #expect(IntakeFiles.candidateName("Report.PDF", attempt: 2) == "Report (2).PDF")
        #expect(IntakeFiles.candidateName("Report.PDF", attempt: 3) == "Report (3).PDF")
        #expect(IntakeFiles.candidateName("a.b.md", attempt: 2) == "a.b (2).md")
        #expect(IntakeFiles.candidateName("notes", attempt: 2) == "notes (2)")
    }

    @Test func copiesIntoTheInboxAndNeverMoves() async throws {
        let (source, library) = try sourceAndLibrary("Meadows Systems.pdf")
        let copy = try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc)
        #expect(copy.libraryPath == "inbox/2026-11/Meadows Systems.pdf")
        #expect(copy.url.path == library.appending(path: "inbox/2026-11/Meadows Systems.pdf").path)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: copy.url) == Data(contentsOf: source))
    }

    @Test func aNameAlreadyInTheInboxGetsTheNextNumber() async throws {
        let (source, library) = try sourceAndLibrary("Scan.PDF")
        let first = try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc)
        let second = try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc)
        let third = try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc)
        #expect([first, second, third].map(\.libraryPath) == [
            "inbox/2026-11/Scan.PDF", "inbox/2026-11/Scan (2).PDF", "inbox/2026-11/Scan (3).PDF",
        ])
        #expect([first, second, third].allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    /// The API follows links before its containment check: a copied link would be refused.
    @Test func copiesWhatASymlinkPointsTo() async throws {
        let (source, library) = try sourceAndLibrary("real.pdf")
        let link = source.deletingLastPathComponent().appending(path: "Paper.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let copy = try await IntakeFiles.copy(link, into: library, at: november4, calendar: utc)
        #expect(copy.libraryPath == "inbox/2026-11/Paper.pdf")
        let values = try copy.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        #expect(values.isSymbolicLink == false && values.isRegularFile == true)
    }

    @Test func refusesAFolderWithADocumentsName() async throws {
        let (_, library) = try sourceAndLibrary("unused.pdf")
        let folder = try temporaryDirectory().appending(path: "book.epub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await #expect(throws: IntakeFiles.CopyError.self) {
            try await IntakeFiles.copy(folder, into: library, at: november4, calendar: utc)
        }
        #expect(!FileManager.default.fileExists(atPath: library.appending(path: "inbox/2026-11/book.epub").path))
    }

    @Test func removesACopy() async throws {
        let (source, library) = try sourceAndLibrary("x.md")
        let copy = try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc)
        try IntakeFiles.remove(copy)
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    /// A big file from USB, SMB or iCloud must not freeze the window: the copy runs off the
    /// main thread even when the main actor asks for it.
    @MainActor
    @Test func copiesOffTheMainThread() async throws {
        let (source, library) = try sourceAndLibrary("big.pdf")
        let probe = ProbeFileManager(failsHalfway: false)
        _ = try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc, fileManager: probe)
        #expect(probe.copiedOnMainThread == false)
    }

    /// A disk that fills up half-way: the error reaches the caller and no partial copy stays.
    @Test func aFailedCopyLeavesNothingBehind() async throws {
        let (source, library) = try sourceAndLibrary("x.pdf")
        let probe = ProbeFileManager(failsHalfway: true)
        await #expect(throws: CocoaError.self) {
            try await IntakeFiles.copy(source, into: library, at: november4, calendar: utc, fileManager: probe)
        }
        #expect(!FileManager.default.fileExists(atPath: library.appending(path: "inbox/2026-11/x.pdf").path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

/// Records which thread copied; can write part of the file and then fail as a full disk does.
final class ProbeFileManager: FileManager, @unchecked Sendable {
    let failsHalfway: Bool
    private(set) var copiedOnMainThread: Bool?

    init(failsHalfway: Bool) {
        self.failsHalfway = failsHalfway
        super.init()
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        copiedOnMainThread = Thread.isMainThread
        guard failsHalfway else { return try super.copyItem(at: source, to: destination) }
        try Data("%PDF-1.7 half".utf8).write(to: destination)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

// MARK: Fixtures shared by the intake tests

let november4 = Date(timeIntervalSince1970: 1_793_786_400)  // 2026-11-04T10:00:00Z

let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A file named `name` in a fresh "Downloads" folder, and an empty `library/`.
func sourceAndLibrary(_ name: String, contents: String = "%PDF-1.7 test") throws -> (source: URL, library: URL) {
    let root = try temporaryDirectory()
    let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
    let library = root.appending(path: "library", directoryHint: .isDirectory)
    for folder in [downloads, library] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let source = downloads.appending(path: name)
    try contents.write(to: source, atomically: true, encoding: .utf8)
    return (source, library)
}
