import AppKit

/// The menu actions of §8, their validation, and the Server menu's status lines.
extension AppDelegate: NSMenuItemValidation, NSMenuDelegate {
    // MARK: File, View, Go

    @objc func printPage(_ sender: Any?) {
        guard let window = windowController.window else { return }
        page.print(in: window)
    }

    @objc func reloadPage(_ sender: Any?) {
        page.webView.reload()
        windowController.showPage()
    }

    @objc func actualSize(_ sender: Any?) { page.resetZoom() }
    @objc func zoomIn(_ sender: Any?) { page.zoom(in: true) }
    @objc func zoomOut(_ sender: Any?) { page.zoom(in: false) }
    @objc func goBack(_ sender: Any?) { page.webView.goBack() }
    @objc func goForward(_ sender: Any?) { page.webView.goForward() }

    /// WebKit has no public call that opens the inspector; say where it is.
    @objc func showWebInspector(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Web Inspector"
        alert.informativeText = "Control-click the page and choose Inspect Element, or open it from Safari's Develop menu."
        alert.runModal()
    }

    @objc func goToPage(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        windowController.showWindow(nil)
        page.open(path: path)
    }

    // MARK: Server

    @objc func restartServices(_ sender: Any?) {
        startServices(restart: true)
    }

    @objc func restartAPI(_ sender: Any?) {
        Task {
            if let failure = await supervisor.restart(.api) { show(failure) }
        }
    }

    @objc func rebuildWeb(_ sender: Any?) {
        windowController.showLoading()
        syncLoadingView()
        page.reset()
        Task {
            if let failure = await supervisor.restart(.web, rebuild: true) {
                show(failure)
            } else {
                page.webView.reload()
            }
        }
    }

    @objc func toggleJobQueue(_ sender: Any?) {
        let pause = !(lastQueue?.paused ?? false)
        Task {
            if let queue = await JobsAPI.setPaused(pause) {
                lastQueue = queue
                Log.info("job queue \(queue.paused ? "paused" : "resumed")")
            } else {
                Log.error("the job queue did not answer")
            }
        }
    }

    @objc func revealLibrary(_ sender: Any?) {
        guard let repo = supervisor.context?.repo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repo.library])
    }

    @objc func openAPIDocs(_ sender: Any?) { NSWorkspace.shared.open(Loopback.apiDocs) }
    @objc func showLogs(_ sender: Any?) { NSWorkspace.shared.open(paths.logs) }

    @objc func openReadme(_ sender: Any?) {
        guard let repo = supervisor.context?.repo else { return }
        NSWorkspace.shared.open(repo.readme)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let pageShown = windowController?.isShowingPage ?? false
        let ready = supervisor.phase == .ready
        switch action {
        case #selector(printPage(_:)), #selector(reloadPage(_:)), #selector(actualSize(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(goToPage(_:)):
            return pageShown
        case #selector(goBack(_:)):
            return pageShown && page.webView.canGoBack
        case #selector(goForward(_:)):
            return pageShown && page.webView.canGoForward
        case #selector(showWebInspector(_:)):
            item.isHidden = !preferences.webInspectorEnabled
            return preferences.webInspectorEnabled
        case #selector(restartServices(_:)):
            return supervisor.phase == .ready || supervisor.phase == .failed
        case #selector(restartAPI(_:)), #selector(rebuildWeb(_:)), #selector(openAPIDocs(_:)):
            return ready
        case #selector(addToLibrary(_:)), #selector(addWebArticle(_:)):
            return Self.canAddToLibrary(phase: supervisor.phase, sheetOpen: windowController?.window?.attachedSheet != nil)
        case #selector(toggleJobQueue(_:)):
            item.title = lastQueue?.paused == true ? "Resume Job Queue" : "Pause Job Queue"
            return ready
        case #selector(revealLibrary(_:)), #selector(openReadme(_:)):
            return supervisor.context != nil
        default:
            return true
        }
    }

    /// ⌘O and ⇧⌘O post to the API, so they wait for the services. Not while a sheet is on
    /// the window either: a second panel would queue, unseen, behind the open one.
    static func canAddToLibrary(phase: Supervisor.Phase, sheetOpen: Bool) -> Bool {
        phase == .ready && !sheetOpen
    }

    // MARK: Server menu status lines

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusLines(in: menu)
        guard supervisor.phase == .ready else { return }
        Task {
            lastQueue = await JobsAPI.queue(timeout: 1)
            updateStatusLines(in: menu)
        }
    }

    private func updateStatusLines(in menu: NSMenu) {
        let lines: [(MainMenu.StatusTag, String)] = [
            (.database, "Database: \(describe(.database))"),
            (.api, "API: \(describe(.api))"),
            (.web, "Web: \(describe(.web))"),
            (.jobs, "Jobs: \(supervisor.phase == .ready ? lastQueue?.summary ?? "—" : "—")"),
        ]
        for (tag, title) in lines {
            menu.item(withTag: tag.rawValue)?.title = title
        }
    }

    private func describe(_ step: Supervisor.Step) -> String {
        switch supervisor.state(of: step) {
        case .waiting: "—"
        case .working(let what): what.lowercased() + "…"
        case .done: supervisor.phase == .stopping ? "stopping…" : "running"
        case .failed: "failed"
        }
    }
}
