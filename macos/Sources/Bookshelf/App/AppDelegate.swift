import AppKit

/// The app's lifecycle (M2): start the services, show the page, stop them at quit (§3).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths = AppPaths.standard
    let preferences = Preferences()
    let smoke: SmokeReport
    private(set) lazy var supervisor = Supervisor(paths: paths, preferences: preferences)
    private(set) var page: WebPage!
    private(set) var windowController: MainWindowController!
    /// The job queue as last read (Server menu, Pause / Resume).
    var lastQueue: QueueSummary?
    private var quitting = false
    private var poweringOff = false
    private var signalSource: DispatchSourceSignal?

    init(smoke: SmokeReport) {
        self.smoke = smoke
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false  // before any window exists
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = otherInstance() {
            other.activate()
            exit(0)  // one instance: a second one would fight over the ports and pid files
        }
        try? paths.createDirectories()
        for name in LogName.allCases { LogFiles.rotate(paths.log(name)) }
        AppLogFile.shared.open(paths.log(.app))
        let info = Bundle.main.infoDictionary ?? [:]
        Log.info("launch: Bookshelf \(info["CFBundleShortVersionString"] ?? "dev") (\(info["BookshelfCommit"] ?? "no commit")), pid \(getpid()), \(ProcessInfo.processInfo.operatingSystemVersionString)")

        NSApp.mainMenu = MainMenu.build(serverMenuDelegate: self)
        NSApp.servicesMenu = submenu("Bookshelf")?.item(withTitle: "Services")?.submenu
        NSApp.windowsMenu = submenu("Window")
        NSApp.helpMenu = submenu("Help")

        page = WebPage(preferences: preferences)
        windowController = MainWindowController(page: page)
        wireCallbacks()
        windowController.showWindow(nil)
        NSApp.activate()
        installQuitSignal()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
        startServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.showWindow(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Start

    func startServices(restart: Bool = false) {
        windowController.showLoading()
        page.reset()
        Task {
            let result = restart ? await supervisor.restartServices() : await supervisor.start()
            switch result {
            case .ready:
                smoke.record("ready")
                page.open(path: preferences.reopenLastPage ? preferences.lastPage ?? "/" : "/")
            case .failed(let failure):
                show(failure)
            case .cancelled:
                break
            }
        }
    }

    private func wireCallbacks() {
        supervisor.onChange = { [weak self] in self?.syncLoadingView() }
        supervisor.onServiceDied = { [weak self] failure in self?.show(failure) }
        page.onFirstPaint = { [weak self] in self?.pageShown() }
        page.onLoadFailure = { [weak self] message in
            guard let self else { return }
            show(StartFailure(step: .web, message: "The page did not load: \(message)", log: paths.log(.web)))
        }
        page.onRepeatedCrash = { [weak self] in
            self?.windowController.showError("The page stopped working twice within a minute.", log: "", actions: [
                .init("Reload", isDefault: true) { [weak self] in self?.reloadPage(nil) },
                .init("Quit") { NSApp.terminate(nil) },
            ])
        }
    }

    func syncLoadingView() {
        for step in Supervisor.Step.allCases {
            windowController.loadingView.update(step, supervisor.state(of: step))
        }
    }

    private func pageShown() {
        windowController.showPage()
        smoke.record("shown")
        if smoke.quitWhenShown { pressQuit(because: "smoke: the page is shown") }
    }

    /// The error view (§17): what failed, the end of its log, and the ways out.
    func show(_ failure: StartFailure) {
        var actions: [ErrorView.Action] = [.init("Retry", isDefault: true) { [weak self] in self?.startServices(restart: true) }]
        if let log = failure.log {
            actions.append(.init("Show Log") { NSWorkspace.shared.open(log) })
        }
        actions.append(.init("Quit") { NSApp.terminate(nil) })
        windowController.showError(failure.message, log: failure.log.map { LogFiles.tail($0) } ?? "", actions: actions)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        smoke.record("failed")
        if smoke.quitWhenShown { pressQuit(because: "smoke: the start failed") }
    }

    // MARK: Quit (§3)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateCancel }  // the first quit is still on its way
        quitting = true
        smoke.record("quit")
        Task { await finishQuit() }
        return .terminateLater
    }

    private func finishQuit() async {
        if !poweringOff, preferences.confirmQuitWhileJobsRun, supervisor.phase == .ready,
           let queue = await JobsAPI.queue(timeout: 1), queue.running > 0,
           await !confirmQuit(running: queue.running) {
            quitting = false
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        let since = ContinuousClock.now
        Log.info("quit: stopping the services")
        await supervisor.shutdown()
        Log.info("quit: services stopped in \(since.duration(to: .now))")
        smoke.record("stopped")
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func confirmQuit(running: Int) async -> Bool {
        let alert = NSAlert()
        alert.messageText = running == 1 ? "1 job is running. Quit anyway?" : "\(running) jobs are running. Quit anyway?"
        alert.informativeText = "They go back to the queue and run again next time."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        windowController.showWindow(nil)
        let response = if let window = windowController.window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        let quit = response == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on { preferences.confirmQuitWhileJobsRun = false }
        return quit
    }

    /// SIGTERM (`kill <pid>`, `install-app.sh`) quits as ⌘Q does. A no-op handler, not
    /// `SIG_IGN`: an ignored signal would stay ignored in every child.
    private func installQuitSignal() {
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pressQuit(because: "SIGTERM") }
        }
        source.resume()
        signalSource = source
    }

    /// Presses ⌘Q from a run-loop source, never from a main-queue block (a signal source, a
    /// `Task`): `terminate:` runs its `.terminateLater` loop inside the caller, and the main
    /// queue is not drained while one of its blocks runs, so `finishQuit` would never run.
    private func pressQuit(because reason: String) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                let handled = QuitKey.press()
                Log.info("\(reason): ⌘Q \(handled ? "handled by the Quit menu item" : "not handled; terminating directly")")
                if !handled { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Helpers

    private func otherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != getpid() }
    }

    private func submenu(_ title: String) -> NSMenu? {
        NSApp.mainMenu?.item(withTitle: title)?.submenu
    }
}
