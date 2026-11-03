import Foundation
import os

/// `app.log` plus the unified log, subsystem = bundle id (docs/MACOS_APP.md §16).
enum Log {
    enum Category: String, Sendable {
        case app, supervisor, window
    }

    static func info(_ message: String, _ category: Category = .app) {
        AppLogFile.shared.write(.info, category, message)
    }

    static func error(_ message: String, _ category: Category = .app) {
        AppLogFile.shared.write(.error, category, message)
    }

    /// `2026-11-03T17:20:01.123+01:00`, the stamp on every line the app and its guards write.
    static func timestamp(_ date: Date = Date()) -> String {
        date.ISO8601Format(.iso8601(timeZone: .current, includingFractionalSeconds: true))
    }
}

final class AppLogFile: @unchecked Sendable {
    static let shared = AppLogFile()

    private let lock = NSLock()
    private var handle: FileHandle?
    private let subsystem = Bundle.main.bundleIdentifier ?? "io.github.lacrimae0rerum.bookshelf"

    func open(_ url: URL) {
        let handle = LogFiles.appendHandle(url)
        lock.withLock { self.handle = handle }
    }

    func write(_ level: OSLogType, _ category: Log.Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).log(level: level, "\(message, privacy: .public)")
        let line = "\(Log.timestamp()) [\(category.rawValue)] \(message)\n"
        lock.withLock { handle?.write(Data(line.utf8)) }
    }
}

/// Opening, rotating and reading the tail of log files.
enum LogFiles {
    /// A handle that appends to `url`, creating the file if needed.
    static func appendHandle(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    /// Above `limit` bytes: `x.log` → `x.log.1` → … → `x.log.<keep>`; the oldest is dropped.
    /// Run at launch, before anything writes (§16).
    static func rotate(_ url: URL, limit: Int = 10_000_000, keep: Int = 3) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit else { return }
        let numbered = { (n: Int) in URL(fileURLWithPath: "\(url.path).\(n)") }
        try? fm.removeItem(at: numbered(keep))
        for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: numbered(n).path) {
            try? fm.moveItem(at: numbered(n), to: numbered(n + 1))
        }
        try? fm.moveItem(at: url, to: numbered(1))
    }

    /// The last `lines` lines of `url` (reads at most the last 64 KB).
    static func tail(_ url: URL, lines: Int = 20) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
