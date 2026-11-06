import Foundation
import UniformTypeIdentifiers

/// The files intake takes, and their copy into `library/inbox/<yyyy-mm>/` (§13, M14).
/// The API ingests paths inside `library/` only; the app copies there because its own
/// process holds the person's intent to read from Downloads or Documents.
enum IntakeFiles {
    /// What the API ingests (`SUPPORTED_SUFFIXES` in backend/app/services/library.py).
    static let acceptedExtensions: Set<String> = ["pdf", "epub", "html", "htm", "md"]

    /// The open panel's filter (⌘O), from the same list.
    static var contentTypes: [UTType] {
        Array(Set(acceptedExtensions.compactMap { UTType(filenameExtension: $0) }))
    }

    /// A clash this deep means something else is wrong; stop trying names.
    static let maxAttempts = 999

    /// A copy in the inbox, and the path the API takes for it (relative to `library/`).
    struct Copy: Equatable, Sendable {
        let url: URL
        let libraryPath: String
    }

    enum CopyError: Error, Equatable, LocalizedError {
        case notAFile(String)
        case noFreeName(String)

        var errorDescription: String? {
            switch self {
            case .notAFile(let name): "“\(name)” is not a file."
            case .noFreeName(let name): "The inbox has no free name left for “\(name)”."
            }
        }
    }

    static func isAccepted(_ file: URL) -> Bool {
        acceptedExtensions.contains(file.pathExtension.lowercased())
    }

    /// `2026-11`: the month of `date` in the calendar's time zone.
    static func monthFolder(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// `name` first, then `stem (2).ext`, `stem (3).ext`… The extension keeps its case.
    static func candidateName(_ name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        return suffix.isEmpty ? "\(stem) (\(attempt))" : "\(stem) (\(attempt)).\(suffix)"
    }

    /// Copies (never moves) `file` into `library/inbox/<yyyy-mm>/` under the first free
    /// name, creating the folders. A symlink is followed: the API refuses links that lead
    /// out of the library, so the copy must be the content. `@concurrent`: a big file from
    /// USB, SMB or iCloud copies off the main thread, whoever asks. A copy that fails
    /// (a full disk) leaves no part behind.
    @concurrent
    static func copy(
        _ file: URL, into library: URL, at date: Date, calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) async throws -> Copy {
        let name = file.lastPathComponent
        let source = file.resolvingSymlinksInPath()
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw CopyError.notAFile(name)
        }
        let month = monthFolder(for: date, calendar: calendar)
        let folder = library.appending(path: "inbox/\(month)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Try each name and let the copy fail on a clash: no gap between a check and the copy.
        for attempt in 1...maxAttempts {
            let candidate = candidateName(name, attempt: attempt)
            let target = folder.appending(path: candidate)
            do {
                try fileManager.copyItem(at: source, to: target)
                return Copy(url: target, libraryPath: "inbox/\(month)/\(candidate)")
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                try? fileManager.removeItem(at: target)  // the name was free: this is our part
                throw error
            }
        }
        throw CopyError.noFreeName(name)
    }

    /// Deletes a copy the API did not take. The original was never touched.
    static func remove(_ copy: Copy) throws {
        try FileManager.default.removeItem(at: copy.url)
    }
}
