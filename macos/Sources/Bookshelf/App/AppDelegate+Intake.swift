import AppKit

/// Intake's entry points (§13) and how the window shows what came of them. The logic is in
/// `Integration/Intake.swift`; this is the AppKit around it. Panels and alerts are sheets,
/// never `runModal()`, which would hold the main queue (see `WebPage+Panels.present`).
extension AppDelegate: IntakePresenter {
    // MARK: Entry points

    /// The Dock icon and Finder's *Open With* (§9). A drop that opens the app arrives here
    /// before `applicationDidFinishLaunching`, with no window: intake keeps the files until
    /// the services are ready, which is after the window exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        Log.info("intake: \(files.count) file(s) opened with Bookshelf", .intake)
        intake.receive(files)
    }

    /// File → Add to Library… (⌘O): one or more files of the types intake takes.
    @objc func addToLibrary(_ sender: Any?) {
        guard let window = frontMainWindow() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = IntakeFiles.contentTypes
        panel.prompt = "Add"
        panel.message = "Bookshelf copies the files into library/inbox and adds them to the shelf."
        Task {
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            intake.receive(panel.urls)
        }
    }

    /// File → Add Web Article… (⇧⌘O).
    @objc func addWebArticle(_ sender: Any?) {
        guard let window = frontMainWindow() else { return }
        Task {
            guard let url = await askForWebAddress(on: window) else { return }
            await intake.addWebArticle(url)
        }
    }

    // MARK: IntakePresenter

    /// Opens the page in the window and shows it; then the notice, with *Open* when it
    /// names a document already on the shelf.
    func present(_ report: IntakeReport) async {
        if let path = report.pageToOpen {
            frontMainWindow()
            page.open(path: path)
        }
        guard let notice = report.notice, let window = frontMainWindow() else { return }
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.detail
        if notice.existing != nil { alert.addButton(withTitle: "Open") }
        alert.addButton(withTitle: "OK")
        let answer = await alert.beginSheetModal(for: window)
        if let existing = notice.existing, answer == .alertFirstButtonReturn {
            page.open(path: existing.pagePath)
        }
    }

    // MARK: Helpers

    /// Asks again, with the text kept, until the address is http(s) or the person cancels.
    private func askForWebAddress(on window: NSWindow) async -> URL? {
        var text = ""
        var problem: String?
        while true {
            let field = NSTextField(string: text)
            field.placeholderString = "https://"
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            let alert = NSAlert()
            alert.messageText = "Add Web Article"
            alert.informativeText = problem ?? "Bookshelf fetches the page and adds it to the shelf."
            alert.accessoryView = field
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
            if let url = IntakeAPI.webURL(from: field.stringValue) { return url }
            text = field.stringValue
            problem = "Enter an address that starts with http:// or https://."
        }
    }

    /// The main window, unhidden and in front: a sheet needs it on screen.
    @discardableResult
    private func frontMainWindow() -> NSWindow? {
        NSApp.unhide(nil)
        windowController.showWindow(nil)
        return windowController.window
    }
}
