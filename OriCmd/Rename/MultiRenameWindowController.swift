import AppKit

/// Ctrl+M: Total Commander's Multi-Rename Tool for the selected files.
final class MultiRenameWindowController: NSWindowController {
    private static var shared: MultiRenameWindowController?

    private let nameMaskField = NSTextField(string: "[N]")
    private let extensionMaskField = NSTextField(string: "[E]")
    private let searchField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let regexBox = NSButton(checkboxWithTitle: String(localized: "Regular expressions"), target: nil, action: nil)
    private let caseSensitiveBox = NSButton(checkboxWithTitle: String(localized: "Case sensitive"), target: nil, action: nil)
    private let casePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let counterStartField = NSTextField(string: "1")
    private let counterStepField = NSTextField(string: "1")
    private let counterDigitsField = NSTextField(string: "1")
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: String(localized: "Rename"), target: nil, action: nil)
    private let undoButton = NSButton(title: String(localized: "Undo"), target: nil, action: nil)

    private var items: [FileItem] = []
    private var newNames: [String] = []
    private var conflicts: Set<Int> = []
    private var undoPairs: [(url: URL, newName: String)] = []
    private var onRenamed: (() -> Void)?

    static func show(for items: [FileItem], renamed: @escaping () -> Void) {
        let controller = shared ?? MultiRenameWindowController()
        shared = controller
        controller.items = items
        controller.onRenamed = renamed
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.nameMaskField)
        controller.updatePreview()
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Multi-Rename Tool")
        window.center()
        super.init(window: window)
        window.rememberFrame(as: "MultiRename")
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent() {
        for field in [nameMaskField, extensionMaskField, searchField, replaceField,
                      counterStartField, counterStepField, counterDigitsField] {
            field.delegate = self
        }
        for field in [counterStartField, counterStepField, counterDigitsField] {
            field.widthAnchor.constraint(equalToConstant: 50).isActive = true
        }
        for control in [regexBox, caseSensitiveBox] as [NSButton] {
            control.target = self
            control.action = #selector(optionChanged(_:))
        }
        casePopUp.addItems(withTitles: [
            String(localized: "Unchanged"), String(localized: "lowercase"), String(localized: "UPPERCASE"),
            String(localized: "First letter uppercase"), String(localized: "First Letter Of Each Word"),
        ])
        casePopUp.target = self
        casePopUp.action = #selector(optionChanged(_:))
        renameButton.target = self
        renameButton.action = #selector(rename(_:))
        renameButton.keyEquivalent = "\r"
        undoButton.target = self
        undoButton.action = #selector(undo(_:))
        undoButton.isEnabled = false

        let help = NSTextField(labelWithString:
            "[N] " + String(localized: "name") + "   [N2-5] " + String(localized: "characters") + "   [E] "
            + String(localized: "extension") + "   [C] " + String(localized: "counter") + "   [P] "
            + String(localized: "folder") + "   [YMD] [hms] " + String(localized: "date and time"))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        let counter = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "start")), counterStartField,
            NSTextField(labelWithString: String(localized: "step")), counterStepField,
            NSTextField(labelWithString: String(localized: "digits")), counterDigitsField,
        ])
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Rename mask:")), nameMaskField],
            [NSTextField(labelWithString: String(localized: "Extension:")), extensionMaskField],
            [NSGridCell.emptyContentView, help],
            [NSTextField(labelWithString: String(localized: "Search for:")), searchField],
            [NSTextField(labelWithString: String(localized: "Replace with:")), replaceField],
            [NSGridCell.emptyContentView, NSStackView(views: [regexBox, caseSensitiveBox])],
            [NSTextField(labelWithString: String(localized: "Case:")), casePopUp],
            [NSTextField(labelWithString: String(localized: "Counter [C]:")), counter],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6

        for (identifier, title) in [("old", String(localized: "Old name")), ("new", String(localized: "New name"))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = 340
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail
        let buttons = NSStackView(views: [statusLabel, undoButton, renameButton])

        let stack = NSStackView(views: [grid, scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [grid, scrollView, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    private var rule: MultiRenameRule {
        var rule = MultiRenameRule()
        rule.nameMask = nameMaskField.stringValue
        rule.extensionMask = extensionMaskField.stringValue
        rule.search = searchField.stringValue
        rule.replacement = replaceField.stringValue
        rule.usesRegularExpression = regexBox.state == .on
        rule.isCaseSensitive = caseSensitiveBox.state == .on
        rule.caseMode = MultiRenameRule.CaseMode(rawValue: casePopUp.indexOfSelectedItem) ?? .unchanged
        rule.counterStart = Int(counterStartField.stringValue) ?? 1
        rule.counterStep = Int(counterStepField.stringValue) ?? 1
        rule.counterDigits = Int(counterDigitsField.stringValue) ?? 1
        return rule
    }

    /// Recomputes new names and conflicts: duplicate or invalid names, or names
    /// taken by files that are not being renamed.
    private func updatePreview() {
        let rule = rule
        var error: Error?
        newNames = items.enumerated().map { index, item in
            do {
                return try rule.newName(for: item, at: index)
            } catch let failure {
                error = failure
                return item.name
            }
        }
        // Names are compared within their own folder (files may come from several).
        func key(_ name: String, in folder: URL) -> String {
            folder.standardizedFileURL.path + "/" + name.lowercased()
        }
        let renamedNames = Set(items.map { key($0.name, in: $0.url.deletingLastPathComponent()) })
        var seen: [String: Int] = [:]
        conflicts = []
        for (index, name) in newNames.enumerated() {
            let folder = items[index].url.deletingLastPathComponent()
            let key = key(name, in: folder)
            let invalid = name.isEmpty || name == "." || name == ".." || name.contains("/")
            let taken = !renamedNames.contains(key) && FileManager.default.fileExists(atPath: folder.appending(path: name).path)
            if invalid || taken { conflicts.insert(index) }
            if let other = seen[key] {
                conflicts.formUnion([index, other])
            }
            seen[key] = index
        }
        table.reloadData()
        let changed = zip(items, newNames).count { $0.name != $1 }
        if let error {
            statusLabel.stringValue = error.localizedDescription
        } else if !conflicts.isEmpty {
            statusLabel.stringValue = String(localized: "\(conflicts.count) conflicting names")
        } else {
            statusLabel.stringValue = String(localized: "\(changed) of \(items.count) files will be renamed")
        }
        renameButton.isEnabled = error == nil && conflicts.isEmpty && changed > 0
    }

    @objc private func optionChanged(_ sender: Any?) {
        updatePreview()
    }

    @objc private func rename(_ sender: Any?) {
        updatePreview()
        guard renameButton.isEnabled else {
            NSSound.beep()
            return
        }
        perform(Array(zip(items.map(\.url), newNames)).map { (url: $0.0, newName: $0.1) })
    }

    @objc private func undo(_ sender: Any?) {
        perform(undoPairs)
    }

    private func perform(_ pairs: [(url: URL, newName: String)]) {
        do {
            undoPairs = try BatchRename.rename(pairs)
            undoButton.isEnabled = !undoPairs.isEmpty
            let renamed = Dictionary(uniqueKeysWithValues: pairs.map { ($0.url, $0.newName) })
            items = items.map { item in
                guard let name = renamed[item.url] else { return item }
                return FileItem(name: name, url: item.url.deletingLastPathComponent().appending(path: name),
                                isDirectory: item.isDirectory, isPackage: item.isPackage, isSymlink: item.isSymlink,
                                isHidden: name.hasPrefix("."), size: item.size, modified: item.modified, mode: item.mode)
            }
            updatePreview()
            onRenamed?()
        } catch {
            Prompt.error(String(localized: "Cannot rename"), error, in: window)
        }
    }
}

extension MultiRenameWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updatePreview()
    }
}

extension MultiRenameWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        tableColumn?.identifier.rawValue == "old" ? items[row].name : newNames[safe: row]
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        (cell as? NSTextFieldCell)?.textColor = conflicts.contains(row) ? .systemRed : .labelColor
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
