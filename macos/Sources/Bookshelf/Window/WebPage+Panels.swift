import AppKit
import WebKit

/// New windows, JavaScript panels, file inputs and downloads (§7).
extension WebPage: WKUIDelegate, WKDownloadDelegate {
    /// `target=_blank` and `window.open`: our origin loads in this window; the browser
    /// already has the rest (see `decidePolicyFor`). No second window, ever.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, NavigationPolicy.isOwnOrigin(url) {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    /// The web asks before deleting a collection or a document (`window.confirm`).
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    /// `<input type=file>` (snapshot restore). Without this, WebKit cancels the input.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = frontWindow() else { return nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    // MARK: WKDownloadDelegate (exports, snapshots)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let window = frontWindow(), await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return nil }
        try? FileManager.default.removeItem(at: url)  // the panel already asked to replace it
        Log.info("download to \(url.path)", .window)
        return url
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        Log.error("download failed: \(error.localizedDescription)", .window)
    }

    /// Always a sheet on the window, shown first if it was closed or hidden. Never
    /// `runModal()`: from a WebKit delegate (a main-queue job) it would hold the main queue,
    /// and with it the guards' exit handlers and the quit, until someone answers.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = frontWindow() else { return .cancel }
        return await alert.beginSheetModal(for: window)
    }

    private func frontWindow() -> NSWindow? {
        guard let window = webView.window else { return nil }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
