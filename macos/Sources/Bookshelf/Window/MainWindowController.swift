import AppKit

/// The one main window (§7): the loading view, the error view or the page.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let page: WebPage
    let loadingView = LoadingView()
    let errorView = ErrorView()

    init(page: WebPage) {
        self.page = page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bookshelf"
        window.minSize = NSSize(width: 900, height: 600)
        window.tabbingMode = .disallowed
        window.isRestorable = false  // one mechanism: the last page (§7)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Paper.background
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        window.setFrameAutosaveName("BookshelfMain")  // restores the saved frame, if any
        super.init(window: window)
        window.delegate = self

        let container = PaperView(frame: window.contentLayoutRect)
        window.contentView = container
        for view in [page.webView, loadingView, errorView] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        page.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "Bookshelf" : title
        }
        showLoading()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The page is hidden until its first load finishes, so there is no white flash.
    func showLoading() {
        loadingView.reset()
        show(loadingView)
    }

    func showError(_ headline: String, log: String, actions: [ErrorView.Action]) {
        errorView.show(headline: headline, log: log, actions: actions)
        show(errorView)
    }

    func showPage() {
        show(page.webView)
        window?.makeFirstResponder(page.webView)
    }

    var isShowingPage: Bool { !page.webView.isHidden }

    private func show(_ visible: NSView) {
        for view in [page.webView, loadingView, errorView] as [NSView] {
            view.isHidden = view !== visible
        }
    }

    /// Close is not quit (§7): the red button and ⌘W hide the window; the page, its scroll
    /// position and a narration that is playing stay alive.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
