import Foundation
@testable import Bookshelf

// Stubs and helpers shared by the intake tests. Dates and files: IntakeFilesTests.swift.

let addedReply = HTTPReply(status: 202, body: Data(accepted.utf8))
let duplicateReply = HTTPReply(status: 409, body: Data(#"{"error":{"code":"conflict","message":"This content is already ingested as 'meadows-systems'.","details":[{"document_id":"3f2c3b8e-1d1a-4a59-9a39-6f1f7c2a1b10","slug":"meadows-systems"}]}}"#.utf8))
let meadows = ShelfDocument(id: "3f2c3b8e-1d1a-4a59-9a39-6f1f7c2a1b10", slug: "meadows-systems")

/// An intake on `ready`'s library, with a fixed date, a recording presenter and its own log.
@MainActor
func makeIntake(_ api: StubAPI, ready: ReadyFlag, log: LogRecorder = LogRecorder()) -> (Intake, RecordingPresenter) {
    let intake = Intake(send: api.send, readyLibrary: { ready.library }, now: { november4 }, calendar: utc, log: log.sink)
    let presenter = RecordingPresenter()
    intake.presenter = presenter
    return (intake, presenter)
}

@MainActor
func makeIntake(_ api: StubAPI, library: URL, log: LogRecorder = LogRecorder()) -> (Intake, RecordingPresenter) {
    let ready = ReadyFlag()
    ready.library = library
    return makeIntake(api, ready: ready, log: log)
}

extension Intake {
    /// Hands `files` over and waits for the batch they start, if they start one.
    func receiveAndWait(_ files: [URL]) async {
        await receive(files)?.value
    }
}

/// A second file next to `file`.
func sibling(_ file: URL, _ name: String, contents: String = "%PDF other") throws -> URL {
    let url = file.deletingLastPathComponent().appending(path: name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func exists(_ library: URL, _ path: String) -> Bool {
    FileManager.default.fileExists(atPath: library.appending(path: path).path)
}

/// Waits, without blocking the main actor, until `condition` holds (2 s at most).
@MainActor
func until(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Answers each request with the next reply, `nil` (no answer) once they run out.
@MainActor
final class StubAPI {
    private var replies: [HTTPReply?]
    private(set) var bodies: [[String: String]] = []
    /// Runs as each request arrives (to stop the services mid-batch, say).
    var onSend: (() -> Void)?

    init(_ replies: [HTTPReply?]) {
        self.replies = replies
    }

    var send: HTTPSend {
        { [self] request in await reply(to: request) }
    }

    var paths: [String] { bodies.compactMap { $0["path"] } }

    private func reply(to request: URLRequest) -> HTTPReply? {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        bodies.append(body ?? [:])
        onSend?()
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

@MainActor
final class RecordingPresenter: IntakePresenter {
    private(set) var reports: [IntakeReport] = []

    func present(_ report: IntakeReport) async {
        reports.append(report)
    }
}

/// Keeps the first notice open until `letGo()`, as a person reading an alert does.
@MainActor
final class HoldingPresenter: IntakePresenter {
    private(set) var reports: [IntakeReport] = []
    private(set) var mostOpenAtOnce = 0
    private var open = 0
    private var held: CheckedContinuation<Void, Never>?

    var isHolding: Bool { held != nil }

    func present(_ report: IntakeReport) async {
        open += 1
        mostOpenAtOnce = max(mostOpenAtOnce, open)
        reports.append(report)
        if reports.count == 1 {
            await withCheckedContinuation { held = $0 }
        }
        open -= 1
    }

    func letGo() {
        held?.resume()
        held = nil
    }
}

@MainActor
final class ReadyFlag {
    var library: URL?
}

/// Every line intake would write to `app.log` and the unified log.
@MainActor
final class LogRecorder {
    private(set) var lines: [String] = []

    var sink: IntakeLog {
        IntakeLog(info: { [self] in lines.append($0) }, error: { [self] in lines.append($0) })
    }
}
