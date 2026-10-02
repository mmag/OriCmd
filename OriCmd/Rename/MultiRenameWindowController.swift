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
    private let templatePopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let masksButton = NSButton(title: String(localized: "Use the Masks"), target: nil, action: nil)
    /// New names given one by one (edited, or from a file) instead of the masks.
    private var explicitNames: [String]?
    /// The template loaded last (offered for deleting).
    private var loadedTemplate: String?

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
        window.rememberFrame(as: "MultiRename")
        super.init(window: window)
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
        templatePopUp.target = self
        templatePopUp.action = #selector(templateChosen(_:))
        updateTemplates()
        masksButton.target = self
        masksButton.action = #selector(useMasks(_:))
        masksButton.isEnabled = false
        let editNames = NSButton(title: String(localized: "Edit Names…"), target: self, action: #selector(editNames(_:)))
        let namesFromFile = NSButton(title: String(localized: "Names from File…"), target: self,
                                     action: #selector(namesFromFile(_:)))
        templatePopUp.identifier = NSUserInterfaceItemIdentifier("renameTemplates")
        nameMaskField.identifier = NSUserInterfaceItemIdentifier("renameMask")
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
            [NSTextField(labelWithString: String(localized: "Template:")), templatePopUp],
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
        let buttons = NSStackView(views: [editNames, namesFromFile, masksButton, statusLabel, undoButton, renameButton])

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
            if let explicitNames {
                return index < explicitNames.count && !explicitNames[index].isEmpty ? explicitNames[index] : item.name
            }
            do {
                return try rule.newName(for: item, at: index)
            } catch let failure {
                error = failure
                return item.name
            }
        }
        masksButton.isEnabled = explicitNames != nil
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
        } else if let explicitNames, explicitNames.count != items.count {
            statusLabel.stringValue = String(localized: "\(explicitNames.count) names for \(items.count) files")
        } else if !conflicts.isEmpty {
            statusLabel.stringValue = String(localized: "\(conflicts.count) conflicting names")
        } else {
            statusLabel.stringValue = String(localized: "\(changed) of \(items.count) files will be renamed")
        }
        renameButton.isEnabled = error == nil && conflicts.isEmpty && changed > 0
    }

    @objc private func optionChanged(_ sender: Any?) {
        explicitNames = nil
        updatePreview()
    }

    // MARK: - Templates

    /// The pull-down: the saved rules, Save…, and Delete for the one loaded.
    private func updateTemplates() {
        templatePopUp.removeAllItems()
        templatePopUp.addItem(withTitle: loadedTemplate ?? String(localized: "Saved rules"))
        let templates = MultiRenameRule.templates
        for template in templates {
            templatePopUp.addItem(withTitle: template.name)
            templatePopUp.lastItem?.representedObject = template.name
        }
        if !templates.isEmpty { templatePopUp.menu?.addItem(.separator()) }
        templatePopUp.addItem(withTitle: String(localized: "Save the Rule…"))
        templatePopUp.lastItem?.tag = 1
        if let loadedTemplate, templates.contains(where: { $0.name == loadedTemplate }) {
            templatePopUp.addItem(withTitle: String(localized: "Delete \u{201C}\(loadedTemplate)\u{201D}"))
            templatePopUp.lastItem?.tag = 2
        }
    }

    @objc private func templateChosen(_ sender: Any?) {
        guard let item = templatePopUp.selectedItem else { return }
        if let name = item.representedObject as? String, let template = MultiRenameRule.templates.first(where: { $0.name == name }) {
            apply(template.rule)
            loadedTemplate = name
            updateTemplates()
        } else if item.tag == 1 {
            saveTemplate()
        } else if item.tag == 2, let loadedTemplate {
            MultiRenameRule.templates.removeAll { $0.name == loadedTemplate }
            self.loadedTemplate = nil
            updateTemplates()
        }
    }

    private func saveTemplate() {
        guard let window else { return }
        Prompt.text(String(localized: "Save the rule"), message: String(localized: "Name:"),
                    initial: loadedTemplate ?? nameMaskField.stringValue, okTitle: String(localized: "Save"), in: window) {
            [weak self] text in
            guard let self else { return }
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            var templates = MultiRenameRule.templates.filter { $0.name != name }
            templates.append((name, rule))
            MultiRenameRule.templates = templates
            loadedTemplate = name
            updateTemplates()
        }
    }

    private func apply(_ rule: MultiRenameRule) {
        nameMaskField.stringValue = rule.nameMask
        extensionMaskField.stringValue = rule.extensionMask
        searchField.stringValue = rule.search
        replaceField.stringValue = rule.replacement
        regexBox.state = rule.usesRegularExpression ? .on : .off
        caseSensitiveBox.state = rule.isCaseSensitive ? .on : .off
        casePopUp.selectItem(at: rule.caseMode.rawValue)
        counterStartField.stringValue = String(rule.counterStart)
        counterStepField.stringValue = String(rule.counterStep)
        counterDigitsField.stringValue = String(rule.counterDigits)
        explicitNames = nil
        updatePreview()
    }

    // MARK: - Names one by one

    /// The new names as a text, a line per file, to change by hand.
    @objc private func editNames(_ sender: Any?) {
        guard let window else { return }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        text.string = newNames.joined(separator: "\n")
        text.font = Theme.panelFont
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.identifier = NSUserInterfaceItemIdentifier("renameNames")
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let alert = NSAlert()
        alert.messageText = String(localized: "Edit Names")
        alert.informativeText = String(localized: "A new name per line, in the order of the files.")
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addCancelButton()
        alert.window.initialFirstResponder = text
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.useNames(text.string)
        }
    }

    /// New names from a text file, a line per file.
    @objc private func namesFromFile(_ sender: Any?) {
        #if DEBUG
        if let path = DebugAutomation.takeChosenFile() {
            readNames(from: URL(filePath: path))
            return
        }
        #endif
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.directoryURL = items.first?.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.readNames(from: url) }
        }
    }

    private func readNames(from url: URL) {
        do {
            useNames(try String(contentsOf: url, encoding: .utf8))
        } catch {
            Prompt.error(String(localized: "Cannot read the names"), error, in: window)
        }
    }

    private func useNames(_ text: String) {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        explicitNames = lines
        updatePreview()
    }

    @objc private func useMasks(_ sender: Any?) {
        explicitNames = nil
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
    /// Changing a mask goes back to the masks from names given one by one.
    func controlTextDidChange(_ notification: Notification) {
        explicitNames = nil
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
