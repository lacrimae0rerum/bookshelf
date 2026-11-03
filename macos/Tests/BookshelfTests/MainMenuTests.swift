import AppKit
import Testing
@testable import Bookshelf

/// The menus and shortcuts of docs/MACOS_APP.md §8.
@MainActor
struct MainMenuTests {
    let bar = MainMenu.build(serverMenuDelegate: nil)

    var items: [NSMenuItem] {
        func flatten(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
        }
        return flatten(bar)
    }

    func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers && !$0.isHidden }
    }

    @Test func hasTheMenusInOrder() {
        #expect(bar.items.map(\.title) == ["Bookshelf", "File", "Edit", "View", "Go", "Server", "Window", "Help"])
    }

    @Test func bindsTheShortcutsOfSection8() {
        let expected: [(String, NSEvent.ModifierFlags, Selector)] = [
            ("q", .command, #selector(NSApplication.terminate(_:))),
            ("h", .command, #selector(NSApplication.hide(_:))),
            ("h", [.command, .option], #selector(NSApplication.hideOtherApplications(_:))),
            ("w", .command, #selector(NSWindow.performClose(_:))),
            ("p", .command, #selector(AppDelegate.printPage(_:))),
            ("z", .command, Selector(("undo:"))),
            ("z", [.command, .shift], Selector(("redo:"))),
            ("x", .command, #selector(NSText.cut(_:))),
            ("c", .command, #selector(NSText.copy(_:))),
            ("v", .command, #selector(NSText.paste(_:))),
            ("a", .command, #selector(NSText.selectAll(_:))),
            ("r", .command, #selector(AppDelegate.reloadPage(_:))),
            ("0", .command, #selector(AppDelegate.actualSize(_:))),
            ("+", .command, #selector(AppDelegate.zoomIn(_:))),
            ("-", .command, #selector(AppDelegate.zoomOut(_:))),
            ("f", [.command, .control], #selector(NSWindow.toggleFullScreen(_:))),
            ("i", [.command, .option], #selector(AppDelegate.showWebInspector(_:))),
            ("[", .command, #selector(AppDelegate.goBack(_:))),
            ("]", .command, #selector(AppDelegate.goForward(_:))),
            ("r", [.command, .option], #selector(AppDelegate.restartServices(_:))),
            ("m", .command, #selector(NSWindow.performMiniaturize(_:))),
        ]
        for (key, modifiers, action) in expected {
            #expect(item(key, modifiers)?.action == action, "\(modifiers) \(key)")
        }
    }

    @Test func findUsesTheTextFinder() {
        let tags: [(String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("f", .command, .showFindInterface), ("g", .command, .nextMatch),
            ("g", [.command, .shift], .previousMatch), ("e", .command, .setSearchString),
        ]
        for (key, modifiers, action) in tags {
            let entry = item(key, modifiers)
            #expect(entry?.action == #selector(NSResponder.performTextFinderAction(_:)))
            #expect(entry?.tag == action.rawValue)
        }
    }

    @Test func goMenuOpensTheWebsPages() {
        let paths = (1...6).map { item("\($0)")?.representedObject as? String }
        #expect(paths == ["/", "/library", "/papers", "/pills", "/review", "/pipeline"])
        #expect(items.first { $0.title == "Shelf Settings" }?.representedObject as? String == "/settings")
    }

    @Test func leavesCommandKAndCommandReturnToTheWeb() {
        #expect(item("k") == nil)
        #expect(item("\r") == nil)
    }

    @Test func noTwoVisibleItemsShareAShortcut() {
        let keyed = items.filter { !$0.keyEquivalent.isEmpty && !$0.isHidden }
        let shortcuts = keyed.map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func p2FeaturesShowDisabled() {
        for title in ["Settings…", "Add to Library…", "Add Web Article…"] {
            #expect(items.first { $0.title == title }?.action == nil, "\(title)")
        }
    }

    @Test func serverMenuHasItsStatusLinesAndActions() {
        let server = bar.item(withTitle: "Server")?.submenu
        for tag in MainMenu.StatusTag.allCases {
            #expect(server?.item(withTag: tag.rawValue) != nil)
        }
        #expect(server?.items.compactMap(\.action).contains(#selector(AppDelegate.toggleJobQueue(_:))) == true)
    }
}
