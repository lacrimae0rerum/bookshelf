import AppKit

/// The menu bar of §8, built in code. ⌘K and ⌘↩ stay with the web. Items whose feature
/// comes in P2 (Settings, adding files) are present but have no action, so they show disabled.
@MainActor
enum MainMenu {
    /// Go menu: title, key, path on the web origin.
    static let pages: [(title: String, key: String, path: String)] = [
        ("Today", "1", "/"), ("Library", "2", "/library"), ("Papers", "3", "/papers"),
        ("Pills", "4", "/pills"), ("Review", "5", "/review"), ("Pipeline", "6", "/pipeline"),
    ]

    /// Tags of the Server menu's status lines.
    enum StatusTag: Int, CaseIterable {
        case database = 100, api, web, jobs
    }

    static func build(serverMenuDelegate: NSMenuDelegate?) -> NSMenu {
        let bar = NSMenu()
        for (title, menu) in [
            ("Bookshelf", appMenu()), ("File", fileMenu()), ("Edit", editMenu()), ("View", viewMenu()),
            ("Go", goMenu()), ("Server", serverMenu(delegate: serverMenuDelegate)), ("Window", windowMenu()), ("Help", helpMenu()),
        ] {
            menu.title = title
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        return bar
    }

    static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("About Bookshelf", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", nil, ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Bookshelf", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Bookshelf", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    static func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Add to Library…", nil, "o"))
        menu.addItem(item("Add Web Article…", nil, "o", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(AppDelegate.printPage(_:)), "p"))
        return menu
    }

    /// Required: without it, ⌘C and ⌘V do nothing in a `WKWebView`.
    static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ] {
            let entry = item(title, finder, key, modifiers)
            entry.tag = action.rawValue
            find.addItem(entry)
        }
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Reload", #selector(AppDelegate.reloadPage(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "+"))
        let zoomInEquals = item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "=")  // ⌘= without Shift
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInEquals)
        menu.addItem(item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        menu.addItem(item("Web Inspector", #selector(AppDelegate.showWebInspector(_:)), "i", [.command, .option]))
        return menu
    }

    static func goMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Back", #selector(AppDelegate.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(AppDelegate.goForward(_:)), "]"))
        menu.addItem(.separator())
        for page in pages {
            let entry = item(page.title, #selector(AppDelegate.goToPage(_:)), page.key)
            entry.representedObject = page.path
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let settings = item("Shelf Settings", #selector(AppDelegate.goToPage(_:)))
        settings.representedObject = "/settings"
        menu.addItem(settings)
        return menu
    }

    /// "Server", not "Services": that name belongs to the system submenu.
    static func serverMenu(delegate: NSMenuDelegate?) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = delegate
        for tag in StatusTag.allCases {
            let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            line.tag = tag.rawValue
            menu.addItem(line)
        }
        menu.addItem(.separator())
        menu.addItem(item("Restart Services", #selector(AppDelegate.restartServices(_:)), "r", [.command, .option]))
        menu.addItem(item("Restart API", #selector(AppDelegate.restartAPI(_:))))
        menu.addItem(item("Rebuild Web", #selector(AppDelegate.rebuildWeb(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Pause Job Queue", #selector(AppDelegate.toggleJobQueue(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reveal Library in Finder", #selector(AppDelegate.revealLibrary(_:))))
        menu.addItem(item("Open API Docs", #selector(AppDelegate.openAPIDocs(_:))))
        menu.addItem(item("Show Logs", #selector(AppDelegate.showLogs(_:))))
        return menu
    }

    static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Bookshelf README", #selector(AppDelegate.openReadme(_:))))
        menu.addItem(item("Show Logs", #selector(AppDelegate.showLogs(_:))))
        return menu
    }

    /// Target `nil`: the responder chain, which ends at the app delegate.
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }
}
