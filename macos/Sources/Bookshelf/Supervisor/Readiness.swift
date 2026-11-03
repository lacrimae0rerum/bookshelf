import Foundation

/// "Ready" means the service answers 200 (§4).
enum Readiness {
    enum Outcome: Equatable, Sendable {
        case ready
        case died
        case timedOut
    }

    /// No cache, no cookies, no proxy; a short timeout per try.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func answers200(_ url: URL) async -> Bool {
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Polls `url` every 100 ms until it answers 200, `alive()` turns false, or `timeout`.
    @MainActor
    static func wait(for url: URL, timeout: Duration, alive: () -> Bool) async -> Outcome {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard alive() else { return .died }
            if await answers200(url) { return .ready }
            guard alive() else { return .died }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .timedOut
    }
}
