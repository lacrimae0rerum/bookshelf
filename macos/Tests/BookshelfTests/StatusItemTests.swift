import AppKit
import Testing
@testable import Bookshelf

private let everyIcon: [StatusIcon] = [.starting, .stopping, .notRunning, .ready, .running(2), .paused, .failed]

/// The menu bar icon's image and menu (docs/MACOS_APP.md §10), without a real status bar.
@MainActor
struct StatusItemTests {
    /// The SDK's own symbols, before the app touches them: they exist and are templates, so
    /// macOS tints them for light, dark and tinted menu bars.
    @Test(arguments: everyIcon)
    func everySymbolLoadsAsATemplate(_ icon: StatusIcon) throws {
        let image = try #require(NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil), "\(icon.symbolName)")
        #expect(image.isTemplate, "\(icon.symbolName)")
    }

    @Test(arguments: everyIcon)
    func theImageSaysTheStateToVoiceOver(_ icon: StatusIcon) throws {
        let image = try #require(StatusItem.image(for: icon))
        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == icon.words)
    }

    /// macOS keeps its place across launches (autosave), and ⌘-drag cannot remove it:
    /// without Settings (P2) there would be no way back. A bar of its own, not the system's.
    @Test func keepsItsPlaceAndCannotBeDraggedAway() {
        let bar = NSStatusBar()
        let item = bar.statusItem(withLength: NSStatusItem.variableLength)
        defer { bar.removeStatusItem(item) }
        let menu = NSMenu()
        StatusItem.configure(item, menu: menu)
        #expect(item.autosaveName == "BookshelfStatusItem")
        #expect(!item.behavior.contains(.removalAllowed))
        #expect(item.menu === menu)
    }

    /// The status bar's button: the symbol, and the state in words as its tooltip.
    @Test func drawsTheIconOnItsButton() {
        let button = NSButton()
        StatusItem.draw(.running(2), on: button)
        #expect(button.toolTip == "Bookshelf — ready, 2 jobs running")
        #expect(button.image?.accessibilityDescription == "Bookshelf — ready, 2 jobs running")
        #expect(button.image?.isTemplate == true)
    }
}

/// The icon's menu: the Server menu's status lines, then the everyday actions. Its items
/// target the app delegate, since the app is often inactive when the icon is clicked.
@MainActor
struct StatusMenuTests {
    let delegate = AppDelegate(smoke: SmokeReport(arguments: [], launched: .now))
    var menu: NSMenu { StatusItem.menu(for: delegate) }

    @Test func hasTheStatusLinesThenTheActionsInOrder() {
        let menu = menu
        let tags = menu.items.prefix(4).map(\.tag)
        #expect(tags == MainMenu.StatusTag.allCases.map(\.rawValue))
        let rest = menu.items.dropFirst(4).map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(rest == ["—", "Open Bookshelf", "Add to Library…", "Pause Job Queue", "—", "Restart Services", "—", "Quit Bookshelf"])
    }

    /// Settings stays in P2, and the menu must not promise it.
    @Test func offersNoSettings() {
        #expect(!menu.items.contains { $0.title.hasPrefix("Settings") })
    }

    @Test func itsActionsHaveExplicitTargets() throws {
        let menu = menu
        let expected: [(String, Selector)] = [
            ("Open Bookshelf", #selector(AppDelegate.openBookshelf(_:))),
            ("Add to Library…", #selector(AppDelegate.addToLibrary(_:))),
            ("Pause Job Queue", #selector(AppDelegate.toggleJobQueue(_:))),
            ("Restart Services", #selector(AppDelegate.restartServices(_:))),
        ]
        for (title, action) in expected {
            let entry = try #require(menu.item(withTitle: title))
            #expect(entry.action == action, "\(title)")
            #expect(entry.target === delegate, "\(title)")
        }
        let quit = try #require(menu.item(withTitle: "Quit Bookshelf"))
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.target === NSApplication.shared)
    }

    /// The app delegate fills the status lines as it does the Server menu's.
    @Test func theAppDelegateFillsTheStatusLines() {
        let menu = menu
        #expect(menu.delegate === delegate)
        delegate.menuNeedsUpdate(menu)
        let titles = MainMenu.StatusTag.allCases.map { menu.item(withTag: $0.rawValue)?.title }
        #expect(titles == ["Database: —", "API: —", "Web: —", "Jobs: —"])
    }

    /// Validation goes through the app delegate: with the services not started, only
    /// Open Bookshelf and Quit are offered.
    @Test func validatesThroughTheAppDelegate() {
        let menu = menu
        menu.update()
        let enabled = menu.items.filter { $0.action != nil && $0.isEnabled }.map(\.title)
        #expect(enabled == ["Open Bookshelf", "Quit Bookshelf"])
    }

    @Test func offersResumeWhenTheQueueIsPaused() throws {
        delegate.lastQueue = jobQueue(paused: true)
        let entry = try #require(menu.items.first { $0.action == #selector(AppDelegate.toggleJobQueue(_:)) })
        _ = delegate.validateMenuItem(entry)
        #expect(entry.title == "Resume Job Queue")
    }

    /// The click does what the title said when the menu opened, even when a newer reading of
    /// the queue lands before the click.
    @Test func pauseOrResumeDoesWhatItsTitleSaid() async throws {
        let asked = PauseRecorder(delegate)
        delegate.lastQueue = jobQueue(paused: true)
        let entry = try #require(menu.items.first { $0.action == #selector(AppDelegate.toggleJobQueue(_:)) })
        _ = delegate.validateMenuItem(entry)
        #expect(entry.title == "Resume Job Queue")
        delegate.lastQueue = jobQueue()  // read while the menu was open
        delegate.toggleJobQueue(entry)
        #expect(await until { !asked.values.isEmpty })
        #expect(asked.values == [false])
        #expect(delegate.lastQueue == jobQueue(paused: false))
    }

    /// With no menu item, no title was shown: the last reading decides.
    @Test func withoutAMenuItemTheLastReadingDecides() async {
        let asked = PauseRecorder(delegate)
        delegate.lastQueue = jobQueue(paused: true)
        delegate.toggleJobQueue(nil)
        #expect(await until { !asked.values.isEmpty })
        #expect(asked.values == [false])
    }
}

/// Stands in for `PATCH /jobs/queue`: records what was asked and answers with that queue.
@MainActor
final class PauseRecorder {
    private(set) var values: [Bool] = []

    init(_ delegate: AppDelegate) {
        delegate.setJobQueuePaused = { [weak self] paused in
            self?.values.append(paused)
            return jobQueue(paused: paused)
        }
    }
}

/// How the app delegate keeps the icon current, without running the app: never launched, so
/// the services are idle and there is no status item.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StatusItemWiringTests {
    let delegate = AppDelegate(smoke: SmokeReport(arguments: [], launched: .now))

    /// No poll while the services are not ready, and the queue read for the last ones is
    /// forgotten: the next `.ready` shows the books until the queue is read again.
    @Test func servicesNotReadyMeanNoPollAndNoQueue() {
        delegate.lastQueue = jobQueue(running: 2)
        delegate.supervisorChanged()
        #expect(delegate.lastQueue == nil)
        #expect(delegate.queuePoll.task == nil)
        #expect(delegate.statusIcon == .notRunning)
    }

    /// A supervisor change with the services ready starts the poll; its read lands in
    /// `lastQueue`. The poll is the delegate's own, with a fake phase, queue and clock.
    @Test func aChangeAtReadyStartsThePollIntoLastQueue() async {
        delegate.queuePoll = delegate.makeQueuePoll(
            phase: { .ready },
            read: { jobQueue(running: 2) },
            sleep: { _ in
                try await Task.sleep(for: .seconds(2))  // a stop cancels this at once
                throw CancellationError()  // a broken stop ends the loop, not the test run
            }
        )
        delegate.supervisorChanged()
        #expect(await until { delegate.lastQueue == jobQueue(running: 2) })
        let running = delegate.queuePoll.task
        #expect(running != nil)
        delegate.queuePoll.stop()
        await running?.value
        #expect(running?.isCancelled == true)
    }

    /// Every new reading of the queue redraws the icon.
    @Test func aNewQueueRedrawsTheIcon() {
        let display = IconRecorder()
        delegate.statusItem = display
        delegate.lastQueue = jobQueue(running: 2)
        #expect(display.shown == [.notRunning])
        delegate.lastQueue = nil
        #expect(display.shown == [.notRunning, .notRunning])
    }
}

/// Records what the app delegate asks the menu bar icon to show.
@MainActor
final class IconRecorder: StatusIconDisplay {
    private(set) var shown: [StatusIcon] = []

    func show(_ icon: StatusIcon) {
        shown.append(icon)
    }
}
