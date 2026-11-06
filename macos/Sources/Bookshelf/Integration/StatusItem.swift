import AppKit

/// What draws the menu bar icon: the status item, or a test's recorder.
@MainActor
protocol StatusIconDisplay: AnyObject {
    func show(_ icon: StatusIcon)
}

/// The menu bar icon (§10): an SF Symbol by state (`StatusIcon`) and a menu. Not removable
/// by ⌘-drag: without Settings (P2) there would be no way to bring it back.
@MainActor
final class StatusItem: StatusIconDisplay {
    private let item: NSStatusItem
    private var shown: StatusIcon?

    init(menu: NSMenu) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Self.configure(item, menu: menu)
    }

    /// macOS keeps its place in the menu bar across launches (`autosaveName`). No
    /// `.removalAllowed` in its behaviour: ⌘-drag cannot remove it.
    static func configure(_ item: NSStatusItem, menu: NSMenu) {
        item.autosaveName = "BookshelfStatusItem"
        item.menu = menu
    }

    func show(_ icon: StatusIcon) {
        guard icon != shown, let button = item.button else { return }
        shown = icon
        Self.draw(icon, on: button)
    }

    /// The symbol, and the state in words as the tooltip and the image's description.
    static func draw(_ icon: StatusIcon, on button: NSButton) {
        button.image = image(for: icon)
        button.toolTip = icon.words
    }

    /// Its menu: the Server menu's status lines, then the everyday actions. No Settings
    /// (P2). The items target the app delegate: the app is often inactive when the icon is
    /// clicked, so the responder chain cannot be relied on. The delegate also validates them
    /// and fills the status lines (`menuNeedsUpdate`); both are weak references.
    static func menu(for delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = delegate
        MainMenu.addStatusLines(to: menu)
        menu.addItem(.separator())
        for (title, action) in [
            ("Open Bookshelf", #selector(AppDelegate.openBookshelf(_:))),
            ("Add to Library…", #selector(AppDelegate.addToLibrary(_:))),
            ("Pause Job Queue", #selector(AppDelegate.toggleJobQueue(_:))),
        ] {
            menu.addItem(item(title, action, target: delegate))
        }
        menu.addItem(.separator())
        menu.addItem(item("Restart Services", #selector(AppDelegate.restartServices(_:)), target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Quit Bookshelf", #selector(NSApplication.terminate(_:)), target: NSApplication.shared))
        return menu
    }

    /// The icon's symbol as a template image, so macOS tints it for the menu bar; its
    /// description is the state in words, for VoiceOver.
    static func image(for icon: StatusIcon) -> NSImage? {
        let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: icon.words)
        image?.isTemplate = true
        return image
    }

    private static func item(_ title: String, _ action: Selector, target: AnyObject) -> NSMenuItem {
        let item = MainMenu.item(title, action)
        item.target = target
        return item
    }
}
