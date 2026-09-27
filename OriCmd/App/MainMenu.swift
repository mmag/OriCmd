import AppKit

/// Builds the application menu bar in code (no nib).
///
/// Standard macOS shortcuts (Cmd+Q, Cmd+H, Cmd+C/V, …) are kept as is;
/// Total Commander style menus are added here as their commands appear.
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(container(for: appMenu()))
        mainMenu.addItem(container(for: commandMenu("Files", [
            [.list, .edit],
            [.copy, .renMov, .renameOnly, .mkDir],
            [.delete, .deletePermanently],
        ])))
        mainMenu.addItem(container(for: editMenu()))
        mainMenu.addItem(container(for: commandMenu("Mark", [
            [.spreadSelection, .shrinkSelection],
        ], extra: markItems())))
        mainMenu.addItem(container(for: commandMenu("Commands", [
            [.rereadSource, .exchange],
            [.goToPrevDir, .goToNextDir, .directoryHistory, .goToParent, .goToRoot],
            [.transferLeft, .transferRight, .leftOpenDrives, .rightOpenDrives],
            [.executeDOS],
        ])))
        mainMenu.addItem(container(for: commandMenu("Show", [
            [.srcQuickView],
            [.sortByName, .sortByExt, .sortByDateTime, .sortBySize, .reverseOrder],
            [.switchHidSys],
        ])))

        let windowMenu = windowMenu()
        mainMenu.addItem(container(for: windowMenu))
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        mainMenu.addItem(container(for: helpMenu))
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)

        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))

        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// A menu of commands in groups separated by separators. Each command
    /// gets its shortcut, plus hidden items that make its aliases work.
    private static func commandMenu(_ title: String, _ groups: [[Command]], extra: [NSMenuItem] = []) -> NSMenu {
        let menu = NSMenu(title: title)
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in group {
                let shortcut = command.shortcut
                menu.addItem(item(command.title, command.selector, shortcut?.key ?? "", shortcut?.modifiers ?? []))
                for alias in command.aliases {
                    let hidden = item(command.title, command.selector, alias.key, alias.modifiers)
                    hidden.isHidden = true
                    hidden.allowsKeyEquivalentWhenHidden = true
                    menu.addItem(hidden)
                }
            }
        }
        extra.forEach(menu.addItem)
        return menu
    }

    private static func markItems() -> [NSMenuItem] {
        [
            .separator(),
            item("Select All", #selector(NSText.selectAll(_:))),
            item(Command.clearAll.title, Command.clearAll.selector, "a", [.command, .option]),
            item(Command.exchangeSelection.title, Command.exchangeSelection.selector),
        ]
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func container(for submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
