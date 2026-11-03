import Foundation

/// `state.json` in Application Support (§2). P1 keeps the last PATH capture, the fallback
/// when the login shell does not answer; P2 adds the rebuild fingerprints.
struct AppState: Codable, Equatable, Sendable {
    var path: String?
    var pathCapturedAt: Date?
}

enum StateStore {
    static func load(_ url: URL) -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppState.self, from: data)) ?? AppState()
    }

    static func save(_ state: AppState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
