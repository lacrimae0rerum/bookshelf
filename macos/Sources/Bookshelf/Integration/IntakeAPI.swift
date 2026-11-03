import Foundation

/// A document on the shelf, as the web's pages name it.
struct ShelfDocument: Equatable, Sendable {
    let id: String
    let slug: String?

    /// The document's page; it takes the slug or the id (frontend/src/pages/documents/[ref]).
    var pagePath: String { "/documents/\(slug ?? id)" }
}

/// What became of one file or web article.
enum IntakeOutcome: Equatable, Sendable {
    /// `202`: on the shelf, with its parse job queued. The document is `nil` only when the
    /// body could not be read.
    case added(ShelfDocument?)
    /// `409`: the same content (sha256) is already on the shelf.
    case duplicate(ShelfDocument)
    /// Anything else, in words.
    case failed(String)
    /// Nothing answered. The API may still have taken it, so a copied file is kept; the
    /// path, relative to `library/`, is that copy's.
    case unanswered(keptAt: String?)
    /// Not a type the API takes: nothing was copied or sent.
    case unsupported
}

/// For `app.log`.
extension IntakeOutcome: CustomStringConvertible {
    var description: String {
        switch self {
        case .added(let document): document.map { "added as \($0.slug ?? $0.id)" } ?? "added"
        case .duplicate(let existing): "already on the shelf as \(existing.slug ?? existing.id)"
        case .failed(let message): "not added: \(message)"
        case .unanswered(let kept): "no answer" + (kept.map { "; the copy stays at library/\($0)" } ?? "")
        case .unsupported: "not a type the API takes"
        }
    }
}

/// An HTTP answer, whatever its status.
struct HTTPReply: Equatable, Sendable {
    let status: Int
    let body: Data
}

/// Sends one request; `nil` when nothing answered. Injected so tests use a stub.
typealias HTTPSend = @Sendable (URLRequest) async -> HTTPReply?

/// `POST /api/documents` through the web's `/api` proxy, which adds the API key (§2).
enum IntakeAPI {
    static let documentsURL = Loopback.webOrigin.appending(path: "api/documents")

    enum Source: Equatable, Sendable {
        /// Relative to `library/`, as the API requires: `inbox/2026-11/x.pdf`.
        case libraryPath(String)
        case webURL(URL)
    }

    /// A URL ingest fetches the page first (up to 20 s on the API's side), so this waits
    /// longer than the app's other calls.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// A proxied write must carry the page's origin (as `JobsAPI.setPaused` does).
    static func request(_ source: Source) -> URLRequest {
        var request = URLRequest(url: documentsURL, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Loopback.webOrigin.absoluteString, forHTTPHeaderField: "Origin")
        let body = switch source {
        case .libraryPath(let path): ["path": path]
        case .webURL(let url): ["url": url.absoluteString]
        }
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    static func send(_ request: URLRequest) async -> HTTPReply? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return HTTPReply(status: http.statusCode, body: data)
    }

    /// Any 2xx counts as added: deleting a copy the API took would orphan its document.
    static func outcome(of reply: HTTPReply?) -> IntakeOutcome {
        guard let reply else { return .unanswered(keptAt: nil) }
        if (200..<300).contains(reply.status) {
            return .added(acceptedDocument(reply.body))
        }
        let error = try? decoder.decode(ErrorEnvelope.self, from: reply.body).error
        if reply.status == 409, let existing = error?.details?.lazy.compactMap(\.document).first {
            return .duplicate(existing)
        }
        // The proxy's own 502 (frontend/src/pages/api/[...path].ts): the API may have
        // committed before the connection broke.
        if reply.status == 502, error?.code == upstreamUnavailable {
            return .unanswered(keptAt: nil)
        }
        return .failed(error.map(describe) ?? "The API answered \(reply.status).")
    }

    /// The trimmed text as an `http`/`https` address with a host and no credentials, or
    /// `nil`. Credentials would reach the API's logs and the document's source link. The
    /// scheme is lowercased: the API's pattern is `^https?://`.
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        return parts.url
    }

    // MARK: Bodies

    private static let upstreamUnavailable = "upstream_unavailable"

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Accepted: Decodable {
        struct Document: Decodable {
            let id: String
            let slug: String?
        }

        let document: Document
    }

    /// `{"error": {"code", "message", "details", "request_id"}}` (backend/app/core/errors.py).
    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
            let details: [Detail]?
        }

        /// The 409 carries `document_id` and `slug`; a validation error, `field` and `message`.
        struct Detail: Decodable {
            let documentId: String?
            let slug: String?
            let field: String?
            let message: String?

            var document: ShelfDocument? { documentId.map { ShelfDocument(id: $0, slug: slug) } }
        }

        let error: Body
    }

    private static func acceptedDocument(_ body: Data) -> ShelfDocument? {
        guard let document = try? decoder.decode(Accepted.self, from: body).document else { return nil }
        return ShelfDocument(id: document.id, slug: document.slug)
    }

    /// The message, and the first detail's when there is one ("Request validation failed"
    /// alone says nothing).
    private static func describe(_ error: ErrorEnvelope.Body) -> String {
        let message = error.message ?? "The API refused it."
        guard let detail = error.details?.first, let why = detail.message else { return message }
        return "\(message): \(detail.field.map { "\($0): " } ?? "")\(why)"
    }
}
