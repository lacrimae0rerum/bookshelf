import AppKit
import WebKit

/// The window's one `WKWebView` (M3, §7) and its navigation delegate. UI panels and
/// downloads are in `WebPage+Panels.swift`.
@MainActor
final class WebPage: NSObject, WKNavigationDelegate {
    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    let webView: WKWebView
    let preferences: Preferences
    /// The first page has finished loading: time to show it.
    var onFirstPaint: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    /// The first page failed to load (the error, in words).
    var onLoadFailure: ((String) -> Void)?
    /// The web content process crashed twice within a minute.
    var onRepeatedCrash: (() -> Void)?

    private(set) var painted = false
    private var lastCrash: ContinuousClock.Instant?
    private var observations: [NSKeyValueObservation] = []

    init(preferences: Preferences) {
        self.preferences = preferences
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []  // narrations play at once
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = Paper.background
        webView.pageZoom = preferences.pageZoom
        webView.isInspectable = preferences.webInspectorEnabled
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.onTitleChange?(view.title ?? "") }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.remember(view.url) }
            },
        ]
    }

    /// Loads `path` on our origin; `/` when the path would leave it.
    func open(path: String) {
        let url = NavigationPolicy.url(forPath: path) ?? Loopback.webOrigin
        Log.info("loading \(url.absoluteString)", .window)
        webView.load(URLRequest(url: url))
    }

    /// Starts over, as at launch: the page is shown again after its first load.
    func reset() {
        painted = false
    }

    // MARK: Zoom (⌘+, ⌘-, ⌘0; persisted)

    func zoom(in zoomIn: Bool) {
        let current = webView.pageZoom
        let next = zoomIn ? Self.zoomSteps.first { $0 > current + 0.001 } : Self.zoomSteps.last { $0 < current - 0.001 }
        setZoom(next ?? current)
    }

    func resetZoom() {
        setZoom(1)
    }

    private func setZoom(_ value: Double) {
        webView.pageZoom = value
        preferences.pageZoom = value
    }

    // MARK: Print (⌘P)

    func print(in window: NSWindow) {
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let userInitiated = action.navigationType == .linkActivated || action.targetFrame == nil
        let url = action.request.url
        switch NavigationPolicy.decide(url, mainFrame: mainFrame, userInitiated: userInitiated) {
        case .allow:
            return .allow
        case .openInBrowser:
            if let url { NSWorkspace.shared.open(url) }
            return .cancel
        case .cancel:
            Log.info("navigation refused: \(url?.absoluteString ?? "no URL")", .window)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.lowercased().hasPrefix("attachment")
        return response.isForMainFrame && (attachment || !response.canShowMIMEType) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !painted else { return }
        painted = true
        onFirstPaint?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = ContinuousClock.now
        defer { lastCrash = now }
        Log.error("the web content process ended", .window)
        if let lastCrash, now - lastCrash < .seconds(60) {
            onRepeatedCrash?()
        } else {
            webView.reload()
        }
    }

    private func failed(_ error: any Error) {
        let nsError = error as NSError
        // Cancelled (a newer navigation), or a response turned into a download.
        let benign = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        guard !benign else { return }
        Log.error("page load failed: \(nsError.localizedDescription)", .window)
        if !painted { onLoadFailure?(nsError.localizedDescription) }
    }

    private func remember(_ url: URL?) {
        guard let url, let page = NavigationPolicy.pathAndQuery(url) else { return }
        preferences.lastPage = page
    }
}
