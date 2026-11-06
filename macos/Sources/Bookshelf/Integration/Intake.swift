import Foundation

/// Shows what a batch became: the page to open and the notice, as AppKit does it.
@MainActor
protocol IntakePresenter: AnyObject {
    /// Returns when the person has seen the notice, so two notices never stack.
    func present(_ report: IntakeReport) async
}

/// Where intake writes: `app.log` and the unified log, both public (Support/Log.swift). So a
/// line names a file by its name and its copy in `library/`, and a web page by its scheme and
/// host: never a folder, a path or a query.
struct IntakeLog {
    var info: @MainActor (String) -> Void = { Log.info($0, .intake) }
    var error: @MainActor (String) -> Void = { Log.error($0, .intake) }

    /// `https://example.com`.
    static func site(of url: URL) -> String {
        "\(url.scheme ?? "?")://\(url.host() ?? "?")"
    }

    /// `NSCocoaErrorDomain 513`: an error without its text, which can name folders.
    static func code(of error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

/// Intake (§13): files from the Dock, *Open With*, ⌘O and the window, and web articles
/// (⇧⌘O). Each file is copied into the inbox and posted. A copy the API refused is
/// deleted; one it did not answer for is kept, since it may have taken it. Files that
/// arrive while the services are not ready wait, uncopied, in order.
@MainActor
final class Intake {
    weak var presenter: IntakePresenter?
    /// Files waiting for the services, in the order they came.
    private(set) var pending: [URL] = []

    private let send: HTTPSend
    /// `library/` while the services are ready, `nil` otherwise.
    private let readyLibrary: () -> URL?
    private let now: () -> Date
    private let calendar: Calendar
    private let log: IntakeLog
    /// A batch loop is running; it takes whatever else arrives.
    private var draining = false

    init(
        send: @escaping HTTPSend, readyLibrary: @escaping () -> URL?,
        now: @escaping () -> Date = Date.init, calendar: Calendar = .current, log: IntakeLog = IntakeLog()
    ) {
        self.send = send
        self.readyLibrary = readyLibrary
        self.now = now
        self.calendar = calendar
        self.log = log
    }

    /// Every file entry point. Queues `files`, then starts a batch if the services are
    /// ready: its task, or `nil` when the files wait or a running batch takes them.
    @discardableResult
    func receive(_ files: [URL]) -> Task<Void, Never>? {
        pending += files
        if !files.isEmpty, readyLibrary() == nil {
            log.info("intake: \(files.count) file(s) wait for the services")
        }
        return resumeIfReady()
    }

    /// Starts the batch loop when files wait, the services are ready and no loop runs.
    /// Called on every supervisor change, so what waited goes in once they are ready.
    @discardableResult
    func resumeIfReady() -> Task<Void, Never>? {
        guard !draining, !pending.isEmpty, readyLibrary() != nil else { return nil }
        draining = true  // now, not in the task: a second call meanwhile starts nothing
        return Task { await drain() }
    }

    /// `POST {"url": …}`; the API fetches the page.
    func addWebArticle(_ url: URL) async {
        let outcome = IntakeAPI.outcome(of: await send(IntakeAPI.request(.webURL(url))))
        log.info("intake: web article from \(IntakeLog.site(of: url)): \(outcome)")
        await presenter?.present(.summarizing([IntakeResult(name: url.absoluteString, outcome: outcome)]))
    }

    /// Batch by batch until nothing waits or the services stop. Files that come meanwhile
    /// make the next batch, after the person has seen this one's notice.
    private func drain() async {
        defer { draining = false }
        while !pending.isEmpty, readyLibrary() != nil {
            let batch = pending
            pending.removeAll()
            var results: [IntakeResult] = []
            for (index, file) in batch.enumerated() {
                // Before each file: the services can stop mid-batch (a restart, a crash).
                guard let library = readyLibrary() else {
                    pending.insert(contentsOf: batch[index...], at: 0)
                    log.info("intake: the services stopped; \(batch.count - index) file(s) wait again")
                    break
                }
                results.append(await ingest(file, library: library))
            }
            if !results.isEmpty {
                await presenter?.present(.summarizing(results))
            }
        }
    }

    private func ingest(_ file: URL, library: URL) async -> IntakeResult {
        let name = file.lastPathComponent
        guard IntakeFiles.isAccepted(file) else {
            log.info("intake: \(name): \(IntakeOutcome.unsupported)")
            return IntakeResult(name: name, outcome: .unsupported)
        }
        let copy: IntakeFiles.Copy
        do {
            copy = try await IntakeFiles.copy(file, into: library, at: now(), calendar: calendar)
        } catch {
            log.error("intake: \(name): copy failed (\(IntakeLog.code(of: error)))")
            return IntakeResult(name: name, outcome: .failed("It could not be copied into the library: \(error.localizedDescription)"))
        }
        var outcome = IntakeAPI.outcome(of: await send(IntakeAPI.request(.libraryPath(copy.libraryPath))))
        switch outcome {
        case .duplicate, .failed: delete(copy, of: name)  // §13: the shelf has it, or the API said no
        case .unanswered: outcome = .unanswered(keptAt: copy.libraryPath)  // it may have been taken
        case .added, .unsupported: break
        }
        log.info("intake: \(name) → library/\(copy.libraryPath): \(outcome)")
        return IntakeResult(name: name, outcome: outcome)
    }

    private func delete(_ copy: IntakeFiles.Copy, of name: String) {
        do {
            try IntakeFiles.remove(copy)
        } catch {
            log.error("intake: \(name): could not delete library/\(copy.libraryPath) (\(IntakeLog.code(of: error)))")
        }
    }
}
