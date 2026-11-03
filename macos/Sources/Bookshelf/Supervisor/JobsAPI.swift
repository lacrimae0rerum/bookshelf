import Foundation

/// The job queue, read through the web's `/api` proxy, which holds the API key (§2).
struct QueueSummary: Decodable, Equatable, Sendable {
    let queued: Int
    let running: Int
    let paused: Bool
    let pausedReason: String?

    /// "2 running · 5 queued", "paused", "idle".
    var summary: String {
        if paused { return pausedReason.map { "paused: \($0)" } ?? "paused" }
        if running == 0 && queued == 0 { return "idle" }
        return "\(running) running · \(queued) queued"
    }
}

enum JobsAPI {
    static let queueURL = Loopback.webOrigin.appending(path: "api/jobs/queue")

    static func queue(timeout: TimeInterval = 1) async -> QueueSummary? {
        var request = URLRequest(url: queueURL, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await send(request)
    }

    /// `PATCH /jobs/queue {"paused": …}`. A proxied write must carry the page's origin.
    static func setPaused(_ paused: Bool) async -> QueueSummary? {
        var request = URLRequest(url: queueURL, timeoutInterval: 5)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Loopback.webOrigin.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = Data(#"{"paused":\#(paused)}"#.utf8)
        return await send(request)
    }

    static func decode(_ data: Data) -> QueueSummary? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(QueueSummary.self, from: data)
    }

    private static func send(_ request: URLRequest) async -> QueueSummary? {
        guard let (data, response) = try? await Readiness.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return decode(data)
    }
}
