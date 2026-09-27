import AppKit

/// Builds the application menu bar in code (no nib).
///
/// Standard macOS shortcuts (Cmd+Q, Cmd+H, Cmd+C/V, …) are kept as is;
/// Total Commander style menus are added here as their commands appear.
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(container(for: appMenu()))
        mainMenu.addItem(container(for: commandMenu(String(localized: "Files"), [
            [.list, .edit],
            [.copy, .renMov, .renameOnly, .multiRenameFiles, .mkDir],
            [.delete, .deletePermanently],
            [.packFiles, .unpackFiles],
        ])))
        mainMenu.addItem(container(for: editMenu()))
        mainMenu.addItem(container(for: commandMenu(String(localized: "Mark"), [
            [.spreadSelection, .shrinkSelection],
        ], extra: markItems())))
        mainMenu.addItem(container(for: commandMenu(String(localized: "Commands"), [
            [.rereadSource, .exchange],
            [.openNewTab, .openDirInNewTab, .closeCurrentTab, .switchToNextTab, .switchToPreviousTab],
            [.searchFor, .directoryHotlist],
            [.compareDirs, .syncDirs],
            [.goToPrevDir, .goToNextDir, .directoryHistory, .goToParent, .goToRoot],
            [.transferLeft, .transferRight, .leftOpenDrives, .rightOpenDrives],
            [.executeDOS],
        ])))
        mainMenu.addItem(container(for: commandMenu(String(localized: "Show"), [
            [.srcShort, .srcLong, .srcTree, .srcQuickView],
            [.sortByName, .sortByExt, .sortByDateTime, .sortBySize, .reverseOrder],
            [.switchHidSys],
        ])))

        let windowMenu = windowMenu()
        mainMenu.addItem(container(for: windowMenu))
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: String(localized: "Help"))
        mainMenu.addItem(container(for: helpMenu))
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)

        menu.addItem(item(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())

        let servicesMenu = NSMenu(title: String(localized: "Services"))
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))

        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "edit.copy", defaultValue: "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
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
            item(String(localized: "mark.selectAll", defaultValue: "Select All"), #selector(NSText.selectAll(_:))),
            item(Command.clearAll.title, Command.clearAll.selector, "a", [.command, .option]),
            item(Command.exchangeSelection.title, Command.exchangeSelection.selector),
        ]
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
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
