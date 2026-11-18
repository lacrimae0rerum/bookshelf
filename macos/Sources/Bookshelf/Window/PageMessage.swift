import Foundation
import WebKit

/// What the web page may ask of the app, through
/// `window.webkit.messageHandlers.bookshelf.postMessage(…)`. Only our own origin, main frame.
enum PageMessage: Equatable, Sendable {
    /// The "Add a book" dialog's *Choose files…*: the open panel, then intake. `genre` is the
    /// dialog's "Add as" (`book`, `paper`, `article`); `nil` lets the API detect it.
    case addFiles(genre: String?)

    static let handlerName = "bookshelf"
    static let genres: Set<String> = ["book", "paper", "article"]

    /// `{"action": "addFiles", "genre": "paper"}` → `.addFiles(genre: "paper")`. Anything
    /// else, from anywhere else, is `nil`. An unknown genre is dropped, not trusted.
    static func parse(_ body: Any, origin: URL?, mainFrame: Bool) -> PageMessage? {
        guard mainFrame, let origin, NavigationPolicy.isOwnOrigin(origin),
              let body = body as? [String: Any], body["action"] as? String == "addFiles" else { return nil }
        let genre = (body["genre"] as? String).flatMap { genres.contains($0) ? $0 : nil }
        return .addFiles(genre: genre)
    }

    /// `http://127.0.0.1:4321`, from WebKit's description of a frame's origin.
    static func url(of origin: WKSecurityOrigin) -> URL? {
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host
        parts.port = origin.port == 0 ? nil : origin.port
        return parts.url
    }
}

/// Holds the page weakly: `WKUserContentController` retains its handlers, and the page owns
/// the web view that owns the controller.
final class PageMessageHandler: NSObject, WKScriptMessageHandler {
    private let receive: @MainActor (PageMessage) -> Void

    init(_ receive: @escaping @MainActor (PageMessage) -> Void) {
        self.receive = receive
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let origin = PageMessage.url(of: message.frameInfo.securityOrigin)
            guard let parsed = PageMessage.parse(message.body, origin: origin, mainFrame: message.frameInfo.isMainFrame) else {
                Log.info("page message refused", .window)
                return
            }
            receive(parsed)
        }
    }
}
