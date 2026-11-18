import Foundation
import os

/// `app.log` plus the unified log, subsystem = bundle id (docs/MACOS_APP.md §16).
enum Log {
    enum Category: String, Sendable {
        case app, supervisor, window, intake
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
    /// A handle that appends to `url` (`O_APPEND`), creating the file if needed. Every write
    /// lands at the end, so a file emptied by `rotate(inPlace:)` is written from its start.
    static func appendHandle(_ url: URL) -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Above `limit` bytes: `x.log` → `x.log.1` → … → `x.log.<keep>`; the oldest is dropped.
    /// At launch, before anything writes, the file is moved (§16). `inPlace`, while the
    /// services run: the file is copied to `x.log.1` and emptied, because the services keep
    /// it open and a moved file would go on growing under its new name. Every writer appends
    /// (`O_APPEND`), so the next line goes to the start of the emptied file; a line written
    /// between the copy and the emptying is lost.
    static func rotate(_ url: URL, limit: Int = 10_000_000, keep: Int = 3, inPlace: Bool = false) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit else { return }
        let numbered = { (n: Int) in URL(fileURLWithPath: "\(url.path).\(n)") }
        try? fm.removeItem(at: numbered(keep))
        for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: numbered(n).path) {
            try? fm.moveItem(at: numbered(n), to: numbered(n + 1))
        }
        if inPlace {
            guard (try? fm.copyItem(at: url, to: numbered(1))) != nil else { return }
            truncate(url.path, 0)
        } else {
            try? fm.moveItem(at: url, to: numbered(1))
        }
    }

    /// `rotate(inPlace: true)` for each log every `interval`, while the app runs; cancel the
    /// task to stop it.
    static func rotateWhileRunning(_ logs: [URL], every interval: Duration = .seconds(600)) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while (try? await Task.sleep(for: interval)) != nil {
                for log in logs { rotate(log, inPlace: true) }
            }
        }
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
