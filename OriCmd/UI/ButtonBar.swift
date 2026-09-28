import AppKit

/// Total Commander's button bar as a native, user-customizable toolbar.
/// Each button sends a `cm_*` command through the responder chain; applications
/// dragged onto it become buttons that start them (see ToolbarApps).
final class ButtonBar: NSObject, NSToolbarDelegate {
    private static let buttons: [(Command, String)] = [
        (.rereadSource, "arrow.clockwise"),
        (.srcShort, "square.grid.3x3"),
        (.srcLong, "list.bullet"),
        (.srcThumbs, "photo.on.rectangle"),
        (.srcTree, "list.bullet.indent"),
        (.srcQuickView, "eye"),
        (.goToPrevDir, "chevron.backward"),
        (.goToNextDir, "chevron.forward"),
        (.directoryHotlist, "star"),
        (.openNewTab, "plus.square.on.square"),
        (.searchFor, "magnifyingglass"),
        (.multiRenameFiles, "character.cursor.ibeam"),
        (.compareDirs, "equal.square"),
        (.syncDirs, "arrow.triangle.2.circlepath"),
        (.packFiles, "doc.zipper"),
        (.unpackFiles, "archivebox"),
        (.switchHidSys, "eye.slash"),
        (.executeDOS, "terminal"),
    ]

    private static let defaultItems: [NSToolbarItem.Identifier] = [
        .init(Command.rereadSource.rawValue), .init(Command.srcShort.rawValue), .init(Command.srcLong.rawValue),
        .init(Command.srcTree.rawValue), .init(Command.srcQuickView.rawValue), .space,
        .init(Command.goToPrevDir.rawValue), .init(Command.goToNextDir.rawValue),
        .init(Command.directoryHotlist.rawValue), .space,
        .init(Command.searchFor.rawValue), .init(Command.multiRenameFiles.rawValue), .init(Command.syncDirs.rawValue),
        .init(Command.packFiles.rawValue), .init(Command.unpackFiles.rawValue), .space,
        .init(Command.executeDOS.rawValue),
    ]

    let toolbar = NSToolbar(identifier: "ButtonBar")

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        // Saved in the standard defaults: test runs must not change the user's toolbar.
        toolbar.autosavesConfiguration = !AppDefaults.isTestRun
    }

    /// The applications offered on the bar are the ones on it: one removed in any
    /// way (its menu, or dragged off while customizing) leaves the palette too.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              let path = ToolbarApps.path(from: item.itemIdentifier), !ToolbarApps.all.contains(path) else { return }
        ToolbarApps.all.append(path)
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              let path = ToolbarApps.path(from: item.itemIdentifier) else { return }
        ToolbarApps.all.removeAll { $0 == path }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.buttons.map { NSToolbarItem.Identifier($0.0.rawValue) }
            + UserCommands.all.map { NSToolbarItem.Identifier(Self.userPrefix + $0.id.uuidString) }
            + ToolbarApps.all.map(ToolbarApps.identifier)
            + [.space, .flexibleSpace]
    }

    private static let userPrefix = "user."

    /// The Start menu command a toolbar button stands for.
    static func userCommandID(from identifier: NSToolbarItem.Identifier) -> String? {
        identifier.rawValue.hasPrefix(userPrefix) ? String(identifier.rawValue.dropFirst(userPrefix.count)) : nil
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let path = ToolbarApps.path(from: identifier) {
            let name = ToolbarApps.name(of: path)
            let button = AppButton(path: path)
            button.onRemove = { [weak self] path in self?.removeApplication(path) }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = name
            item.paletteLabel = name
            item.toolTip = name
            item.view = button
            return item
        }
        if let id = Self.userCommandID(from: identifier) {
            guard let command = UserCommands.command(withID: id) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = command.title
            item.paletteLabel = command.title
            item.toolTip = command.command
            item.image = NSImage(systemSymbolName: "play.square", accessibilityDescription: command.title)
            item.action = #selector(MainViewController.runUserCommand(_:))
            item.isBordered = true
            return item
        }
        guard let (command, symbol) = Self.buttons.first(where: { $0.0.rawValue == identifier.rawValue }) else {
            return nil
        }
        let title = command.title.replacingOccurrences(of: "…", with: "")
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.toolTip = command.shortcut.map { "\(title) (\($0.displayString))" } ?? title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.action = command.selector
        item.isBordered = true
        return item
    }
}

extension ButtonBar {
    /// Puts dropped applications on the bar (each once), after the other buttons.
    func addApplications(_ urls: [URL]) {
        for url in urls where ToolbarApps.isApplication(url) {
            let path = url.standardizedFileURL.path
            let identifier = ToolbarApps.identifier(for: path)
            guard !toolbar.items.contains(where: { $0.itemIdentifier == identifier }) else { continue }
            if !ToolbarApps.all.contains(path) {
                ToolbarApps.all.append(path)
            }
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
        }
    }

    func removeApplication(_ path: String) {
        let identifier = ToolbarApps.identifier(for: path)
        while let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) {
            toolbar.removeItem(at: index)
        }
        ToolbarApps.all.removeAll { $0 == path }
    }
}

extension Shortcut {
    /// "⌃F3", "⇧⌘." — the way menus show key equivalents.
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let scalar = key.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) {
            return text + "F\(scalar.value - 0xF704 + 1)"
        }
        switch key {
        case "\r": return text + "↩"
        case "\t": return text + "⇥"
        default: return text + key.uppercased()
        }
    }
}
