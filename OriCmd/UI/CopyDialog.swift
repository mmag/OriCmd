import AppKit

/// Total Commander's F5 / F6 dialog: the target with a name mask ("*.*"),
/// "Only files of this type", Verify, one row of buttons (OK, F2 Queue, Tree,
/// Cancel, Options >>) and, under Options, the overwrite mode and more.
///
/// Keys: Return OK, F2 queue, F7 adds/removes the target in the target list,
/// F8 filter menu, ⌃D directory hotlist, Esc cancels. Right click on OK or
/// F2 Queue switches between copying and moving.
final class CopyDialog: NSObject {
    struct Result {
        var kind: TransferJob.Kind
        var target: String
        var options: TransferOptions
        var queued: Bool
        var toAllSelectedFolders: Bool
    }

    private static var current: CopyDialog?

    private enum Key {
        static let targetList = "CopyTargetList"
        static let targetHistory = "CopyTargetHistory"
        static let filterList = "CopyFilterList"
        static let filterHistory = "CopyFilterHistory"
        static let pinned = "CopyOptionsPinned"
    }

    private static let historyLimit = 15
    private static let buttonWidth: CGFloat = 112

    private let kind: TransferJob.Kind
    private let completion: (Result) -> Void
    private let panel = CopyDialogPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
                                        styleMask: [.titled], backing: .buffered, defer: true)
    private weak var parent: NSWindow?

    private let targetBox = NSComboBox()
    private let targetListButton = NSButton(title: "+ F7", target: nil, action: nil)
    private let filterBox = NSComboBox()
    private let filterButton = NSButton(title: "+ F8", target: nil, action: nil)
    private let attributesBox = NSButton(checkboxWithTitle: String(localized: "Copy extended attributes and ACLs"),
                                         target: nil, action: nil)
    private let verifyBox = NSButton(checkboxWithTitle: String(localized: "Verify"), target: nil, action: nil)
    private let okButton = NSButton(title: String(localized: "OK"), target: nil, action: nil)
    private let queueButton = NSButton(title: String(localized: "F2 Queue"), target: nil, action: nil)
    private let optionsButton = NSButton(title: String(localized: "Options >>"), target: nil, action: nil)
    private let advanced = NSBox()
    private let pinButton = NSButton()
    private let overwritePopUp = NSPopUpButton()
    private let saveButton = NSButton()
    private let skipUnreadableBox = NSButton(checkboxWithTitle: String(localized: "Skip all which cannot be opened for reading"),
                                             target: nil, action: nil)
    private let overwriteLockedBox = NSButton(checkboxWithTitle: String(localized: "Overwrite/delete locked files"),
                                              target: nil, action: nil)
    private let allFoldersBox = NSButton(checkboxWithTitle: String(localized: "Copy to all selected folders in the target panel"),
                                         target: nil, action: nil)

    /// Shows the dialog as a sheet of `window`. `target` is the folder (ending in "/");
    /// `selectedTargetFolders` is the number of folders marked in the target panel.
    static func show(kind: TransferJob.Kind, files: Int, folders: Int, target: String, selectedTargetFolders: Int,
                     in window: NSWindow, completion: @escaping (Result) -> Void) {
        let dialog = CopyDialog(kind: kind, completion: completion)
        current = dialog
        dialog.present(files: files, folders: folders, target: target, selectedTargetFolders: selectedTargetFolders,
                       in: window)
    }

    private init(kind: TransferJob.Kind, completion: @escaping (Result) -> Void) {
        self.kind = kind
        self.completion = completion
        super.init()
    }

    // MARK: - Layout

    private func present(files: Int, folders: Int, target: String, selectedTargetFolders: Int, in window: NSWindow) {
        parent = window
        let message = NSTextField(labelWithString: Self.message(kind: kind, files: files, folders: folders))

        targetBox.stringValue = target + "*.*"
        targetBox.completes = false
        targetBox.numberOfVisibleItems = 12
        targetBox.delegate = self
        targetListButton.target = self
        targetListButton.action = #selector(toggleTargetList(_:))
        targetListButton.keyEquivalent = Self.functionKey(7)
        targetListButton.toolTip = String(localized: "Add the target to the target list, or remove it (F7). ⌃D: directory hotlist")
        filterBox.completes = false
        filterBox.numberOfVisibleItems = 12
        filterButton.target = self
        filterButton.action = #selector(showFilterMenu(_:))
        filterButton.keyEquivalent = Self.functionKey(8)
        filterButton.toolTip = String(localized: "Saved filters and examples (F8)")
        for button in [targetListButton, filterButton] {
            button.widthAnchor.constraint(equalToConstant: 58).isActive = true
            // They have F7 / F8; Tab goes straight from the target to the filter.
            button.refusesFirstResponder = true
        }
        reloadTargetItems()
        reloadFilterItems()

        let store = AppDefaults.store
        attributesBox.state = Settings.copyAttributes ? .on : .off
        verifyBox.state = Settings.copyVerifies ? .on : .off

        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        queueButton.keyEquivalent = Self.functionKey(2)
        let treeButton = NSButton(title: String(localized: "Tree"), target: self, action: #selector(chooseFolder(_:)))
        okButton.target = self
        okButton.action = #selector(confirm(_:))
        queueButton.target = self
        queueButton.action = #selector(confirm(_:))
        optionsButton.target = self
        optionsButton.action = #selector(expand(_:))
        for button in [okButton, queueButton] {
            button.menu = switchMenu()
        }
        let buttons = [okButton, queueButton, treeButton, cancelButton, optionsButton]
        for button in buttons {
            button.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = 8

        buildAdvanced(selectedTargetFolders: selectedTargetFolders)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [
            message,
            row(targetBox, targetListButton),
            NSTextField(labelWithString: String(localized: "Only files of this type:")),
            row(filterBox, filterButton),
            row(attributesBox, spacer, verifyBox),
            buttonRow,
            advanced,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[4])
        stack.setCustomSpacing(14, after: buttonRow)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        for view in stack.arrangedSubviews where view !== message && view !== buttonRow {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 5 * Self.buttonWidth + 4 * 8 + 40).isActive = true

        panel.contentView = stack
        panel.defaultButtonCell = okButton.cell as? NSButtonCell
        panel.initialFirstResponder = targetBox
        panel.autorecalculatesKeyViewLoop = true
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        advanced.isHidden = !store.bool(forKey: Key.pinned)
        optionsButton.isHidden = !advanced.isHidden
        panel.setContentSize(stack.fittingSize)

        window.beginSheet(panel)
        DispatchQueue.main.async { [targetBox] in
            targetBox.currentEditor()?.selectAll(nil)
        }
    }

    private func buildAdvanced(selectedTargetFolders: Int) {
        let store = AppDefaults.store
        pinButton.setButtonType(.toggle)
        pinButton.bezelStyle = .toolbar
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: String(localized: "Keep options open"))
        pinButton.alternateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinButton.state = store.bool(forKey: Key.pinned) ? .on : .off
        pinButton.toolTip = String(localized: "Always show these options")
        pinButton.target = self
        pinButton.action = #selector(togglePin(_:))

        for mode in OverwriteMode.allCases {
            overwritePopUp.addItem(withTitle: mode.title)
        }
        overwritePopUp.selectItem(at: Settings.copyOverwriteMode.rawValue - 1)
        saveButton.bezelStyle = .toolbar
        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down",
                                   accessibilityDescription: String(localized: "Save as default"))
        saveButton.toolTip = String(localized: "Save these options as the default")
        saveButton.target = self
        saveButton.action = #selector(saveDefaults(_:))

        skipUnreadableBox.state = Settings.copySkipsUnreadable ? .on : .off
        overwriteLockedBox.state = Settings.copyOverwritesLocked ? .on : .off
        allFoldersBox.isEnabled = selectedTargetFolders > 0
        if selectedTargetFolders > 0 {
            allFoldersBox.title = String(localized: "Copy to all \(selectedTargetFolders) selected folders in the target panel")
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let content = NSStackView(views: [
            row(NSTextField(labelWithString: String(localized: "Overwrite options")), spacer, pinButton),
            row(overwritePopUp, saveButton),
            skipUnreadableBox,
            overwriteLockedBox,
            allFoldersBox,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        for view in content.arrangedSubviews.prefix(2) {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -16).isActive = true
        }
        advanced.title = String(localized: "Advanced options")
        // Pinned to the box's content view, so the box gets the height it needs.
        content.translatesAutoresizingMaskIntoConstraints = false
        advanced.contentView?.addSubview(content)
        if let box = advanced.contentView {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: box.topAnchor),
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
        }
    }

    private func row(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = 6
        row.distribution = .fill
        views.first?.setContentHuggingPriority(.init(200), for: .horizontal)
        return row
    }

    private static func message(kind: TransferJob.Kind, files: Int, folders: Int) -> String {
        switch (kind, files, folders) {
        case (.copy, _, 0): String(localized: "Copy \(files) file(s) to:")
        case (.copy, 0, _): String(localized: "Copy \(folders) folder(s) to:")
        case (.copy, _, _): String(localized: "Copy \(files) file(s) and \(folders) folder(s) to:")
        case (.move, _, 0): String(localized: "Rename/move \(files) file(s) to:")
        case (.move, 0, _): String(localized: "Rename/move \(folders) folder(s) to:")
        case (.move, _, _): String(localized: "Rename/move \(files) file(s) and \(folders) folder(s) to:")
        }
    }

    private static func functionKey(_ number: Int) -> String {
        String(UnicodeScalar(UInt32(NSF1FunctionKey + number - 1))!)
    }

    // MARK: - Lists

    private static func list(_ key: String) -> [String] {
        AppDefaults.store.stringArray(forKey: key) ?? []
    }

    private static func setList(_ list: [String], _ key: String) {
        AppDefaults.store.set(list, forKey: key)
    }

    /// The folder part of the target text ("/Users/me/*.*" → "/Users/me/").
    private var targetFolder: String {
        let text = targetBox.stringValue
        guard let slash = text.lastIndex(of: "/") else { return text }
        return String(text[...slash])
    }

    private func reloadTargetItems() {
        let saved = Self.list(Key.targetList)
        let history = Self.list(Key.targetHistory).filter { !saved.contains($0) }
        targetBox.removeAllItems()
        targetBox.addItems(withObjectValues: (saved + history).map { $0 + "*.*" })
        updateTargetListButton()
    }

    private func updateTargetListButton() {
        targetListButton.title = Self.list(Key.targetList).contains(targetFolder) ? "− F7" : "+ F7"
    }

    private func reloadFilterItems() {
        let saved = Self.list(Key.filterList)
        let history = Self.list(Key.filterHistory).filter { !saved.contains($0) }
        filterBox.removeAllItems()
        filterBox.addItems(withObjectValues: saved + history)
    }

    /// "+F7": adds the target folder to the target list, or removes it.
    @objc private func toggleTargetList(_ sender: Any?) {
        let folder = targetFolder
        guard folder.hasPrefix("/") || folder.hasPrefix("~") else {
            NSSound.beep()
            return
        }
        var saved = Self.list(Key.targetList)
        if let index = saved.firstIndex(of: folder) {
            saved.remove(at: index)
        } else {
            saved.append(folder)
        }
        Self.setList(saved, Key.targetList)
        reloadTargetItems()
    }

    /// "+F8": saved filters, adding or removing the current one, and examples.
    @objc private func showFilterMenu(_ sender: Any?) {
        let menu = NSMenu()
        let current = filterBox.stringValue.trimmingCharacters(in: .whitespaces)
        let saved = Self.list(Key.filterList)
        if !current.isEmpty {
            let isSaved = saved.contains(current)
            let toggle = NSMenuItem(title: isSaved ? String(localized: "Remove \u{201C}\(current)\u{201D} from the list")
                                        : String(localized: "Add \u{201C}\(current)\u{201D} to the list"),
                                    action: #selector(toggleFilterList(_:)), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
        }
        if !saved.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for filter in saved {
                menu.addItem(filterItem(filter, title: filter))
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let examples = NSMenuItem(title: String(localized: "Examples"), action: nil, keyEquivalent: "")
        examples.isEnabled = false
        menu.addItem(examples)
        for (filter, title) in [
            ("*.jpg *.jpeg *.png *.gif *.heic", String(localized: "Pictures")),
            ("*.txt *.md *.rtf *.pdf *.doc *.docx", String(localized: "Documents")),
            ("*.* | .git/ node_modules/ .DS_Store", String(localized: "Everything except .git, node_modules, .DS_Store")),
            ("src/", String(localized: "Only folders named src, at any depth")),
        ] {
            menu.addItem(filterItem(filter, title: "\(filter)  —  \(title)"))
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: String(localized: "Copy all files"), action: #selector(clearFilter(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.height + 4), in: filterButton)
    }

    private func filterItem(_ filter: String, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseFilter(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = filter
        return item
    }

    @objc private func toggleFilterList(_ sender: Any?) {
        let current = filterBox.stringValue.trimmingCharacters(in: .whitespaces)
        var saved = Self.list(Key.filterList)
        if let index = saved.firstIndex(of: current) {
            saved.remove(at: index)
        } else {
            saved.append(current)
        }
        Self.setList(saved, Key.filterList)
        reloadFilterItems()
    }

    @objc private func chooseFilter(_ sender: NSMenuItem) {
        filterBox.stringValue = sender.representedObject as? String ?? ""
    }

    @objc private func clearFilter(_ sender: Any?) {
        filterBox.stringValue = ""
    }

    /// ⌃D: a folder from the directory hotlist becomes the target.
    private func showHotlist() {
        let menu = NSMenu()
        for path in Hotlist.directories {
            let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath,
                                  action: #selector(chooseHotlistFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: String(localized: "The directory hotlist is empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: targetBox.bounds.height + 4), in: targetBox)
    }

    @objc private func chooseHotlistFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        setTargetFolder(path)
    }

    private func setTargetFolder(_ path: String) {
        let text = targetBox.stringValue
        let mask = text.lastIndex(of: "/").map { String(text[text.index(after: $0)...]) } ?? "*.*"
        targetBox.stringValue = (path.hasSuffix("/") ? path : path + "/") + (mask.isEmpty ? "*.*" : mask)
        updateTargetListButton()
    }

    // MARK: - Actions

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .control, event.shortcutCharacters == "d" {
            showHotlist()
            return true
        }
        return false
    }

    /// "Tree": picks the target folder.
    @objc private func chooseFolder(_ sender: Any?) {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.prompt = String(localized: "Choose")
        let folder = (targetFolder as NSString).expandingTildeInPath
        if folder.hasPrefix("/") {
            open.directoryURL = URL(filePath: folder, directoryHint: .isDirectory)
        }
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            self?.setTargetFolder(url.path)
        }
    }

    @objc private func expand(_ sender: Any?) {
        advanced.isHidden = false
        optionsButton.isHidden = true
        resize()
        panel.makeFirstResponder(overwritePopUp)
    }

    @objc private func togglePin(_ sender: NSButton) {
        AppDefaults.store.set(sender.state == .on, forKey: Key.pinned)
    }

    @objc private func saveDefaults(_ sender: Any?) {
        Settings.copyOverwriteMode = OverwriteMode(rawValue: overwritePopUp.indexOfSelectedItem + 1) ?? .ask
        Settings.copySkipsUnreadable = skipUnreadableBox.state == .on
        Settings.copyOverwritesLocked = overwriteLockedBox.state == .on
        Settings.copyVerifies = verifyBox.state == .on
        Settings.copyAttributes = attributesBox.state == .on
        saveButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [saveButton] in
            saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        }
    }

    private func resize() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = panel.frame
        let height = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: true)
    }

    private func switchMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: kind == .copy ? String(localized: "move.button", defaultValue: "Move")
                                  : String(localized: "copy.button", defaultValue: "Copy"),
                              action: #selector(confirmSwitched(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func confirm(_ sender: NSButton) {
        finish(kind: kind, queued: sender === queueButton)
    }

    /// The right-click menu of OK / F2 Queue: the other operation.
    @objc private func confirmSwitched(_ sender: NSMenuItem) {
        let queued = sender.menu === queueButton.menu
        finish(kind: kind == .copy ? .move : .copy, queued: queued)
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    private func finish(kind: TransferJob.Kind, queued: Bool) {
        let target = targetBox.stringValue.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            NSSound.beep()
            return
        }
        let filter = filterBox.stringValue.trimmingCharacters(in: .whitespaces)
        remember(targetFolder, in: Key.targetHistory)
        if !filter.isEmpty {
            remember(filter, in: Key.filterHistory)
        }
        var options = TransferOptions()
        options.filter = CopyFilter(filter)
        options.verify = verifyBox.state == .on
        options.copiesAttributes = attributesBox.state == .on
        options.overwrite = OverwriteMode(rawValue: overwritePopUp.indexOfSelectedItem + 1) ?? .ask
        options.skipsUnreadable = skipUnreadableBox.state == .on
        options.overwritesLocked = overwriteLockedBox.state == .on
        let result = Result(kind: kind, target: target, options: options, queued: queued,
                            toAllSelectedFolders: allFoldersBox.isEnabled && allFoldersBox.state == .on)
        close()
        completion(result)
    }

    private func remember(_ value: String, in key: String) {
        var list = Self.list(key).filter { $0 != value }
        list.insert(value, at: 0)
        Self.setList(Array(list.prefix(Self.historyLimit)), key)
    }

    private func close() {
        parent?.endSheet(panel)
        panel.orderOut(nil)
        Self.current = nil
    }
}

extension CopyDialog: NSComboBoxDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateTargetListButton()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateTargetListButton() }
    }
}

/// Lets the dialog see ⌃D before the text field does.
private final class CopyDialogPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
