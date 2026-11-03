import Foundation

/// One origin in the window (M13): `http://127.0.0.1:4321`. A link elsewhere that a person
/// followed opens in the default browser; anything else (`file:`, other schemes, a script
/// sending the page away) does not load.
enum NavigationPolicy {
    enum Decision: Equatable {
        case allow
        case openInBrowser
        case cancel
    }

    static func isOwnOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host == Loopback.host && url.port == Int(Loopback.webPort)
            && url.user == nil && url.password == nil
    }

    /// `userInitiated`: a link a person clicked, or a new window (`target=_blank`).
    static func decide(_ url: URL?, mainFrame: Bool, userInitiated: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if isOwnOrigin(url) { return .allow }
        switch scheme {
        case "about":
            return .allow
        case "blob":
            return url.absoluteString.hasPrefix("blob:\(Loopback.webOrigin.absoluteString)/") ? .allow : .cancel
        case "data":
            return mainFrame ? .cancel : .allow
        case "http", "https", "mailto":
            return mainFrame && userInitiated ? .openInBrowser : .cancel
        default:
            return .cancel
        }
    }

    /// `path` (`/library?x=1`) on our origin, or `nil` when it would leave it.
    static func url(forPath path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: Loopback.webOrigin)?.absoluteURL,
              isOwnOrigin(url) else { return nil }
        return url
    }

    /// Path and query of an own-origin URL, as saved for *Reopen the last page*.
    static func pathAndQuery(_ url: URL) -> String? {
        guard isOwnOrigin(url) else { return nil }
        let path = url.path(percentEncoded: true)
        let page = path.isEmpty ? "/" : path
        return url.query(percentEncoded: true).map { "\(page)?\($0)" } ?? page
    }
}
