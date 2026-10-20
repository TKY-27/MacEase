import AppKit

/// Routes key equivalents; agents hide the bar.
enum MainMenu {
    @MainActor
    static func make(openSettings: @escaping @MainActor () -> Void) -> NSMenu {
        let main = NSMenu()
        main.addItem(
            submenu(
                "MacEase",
                [
                    ClosureMenuItem(
                        title: String(localized: "Settings…", comment: "Menu bar item"), keyEquivalent: ",",
                        handler: openSettings)
                ]))
        main.addItem(
            submenu(
                String(localized: "Edit", comment: "Main menu title"),
                [
                    item(String(localized: "Undo", comment: "Edit menu item"), Selector(("undo:")), "z"),
                    item(String(localized: "Redo", comment: "Edit menu item"), Selector(("redo:")), "Z"),
                    .separator(),
                    item(String(localized: "Cut", comment: "Edit menu item"), #selector(NSText.cut(_:)), "x"),
                    item(String(localized: "Copy", comment: "Edit menu item"), #selector(NSText.copy(_:)), "c"),
                    item(String(localized: "Paste", comment: "Edit menu item"), #selector(NSText.paste(_:)), "v"),
                    item(
                        String(localized: "Select All", comment: "Edit menu item"), #selector(NSText.selectAll(_:)),
                        "a"),
                ]))
        main.addItem(
            submenu(
                String(localized: "Window", comment: "Main menu title"),
                [
                    item(
                        String(localized: "Close", comment: "Window menu item"), #selector(NSWindow.performClose(_:)),
                        "w")
                ]))
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
