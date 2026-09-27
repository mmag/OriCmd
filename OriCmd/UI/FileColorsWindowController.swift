import AppKit

/// Settings → File colors: colors for file names by mask, like Total
/// Commander's "Define colors by file type". The first matching rule wins.
final class FileColorsWindowController: NSWindowController {
    static let shared = FileColorsWindowController()

    private let table = NSTableView()
    private let maskField = NSTextField(string: "")
    private let colorWell = NSColorWell(style: .minimal)
    private var rules: [ColorSettings.Rule] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "File Colors")
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        rules = ColorSettings.rules
        table.reloadData()
        if !rules.isEmpty && table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateForm()
        super.showWindow(sender)
    }

    private func buildContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mask"))
        column.title = String(localized: "Mask")
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        maskField.delegate = self
        maskField.placeholderString = "*.zip;*.rar"
        colorWell.target = self
        colorWell.action = #selector(formChanged(_:))
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let form = NSStackView(views: [NSTextField(labelWithString: String(localized: "Mask:")), maskField, colorWell])

        let buttons = NSStackView(views: [
            NSButton(title: String(localized: "Add"), target: self, action: #selector(add(_:))),
            NSButton(title: String(localized: "Remove"), target: self, action: #selector(remove(_:))),
            NSButton(title: String(localized: "Add Examples"), target: self, action: #selector(addExamples(_:))),
        ])
        let stack = NSStackView(views: [scrollView, form, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scrollView, form] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    private var selectedIndex: Int? {
        rules.indices.contains(table.selectedRow) ? table.selectedRow : nil
    }

    private func save(selecting index: Int?) {
        ColorSettings.rules = rules
        table.reloadData()
        if let index, rules.indices.contains(index) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateForm()
    }

    private func updateForm() {
        let rule = selectedIndex.map { rules[$0] }
        maskField.isEnabled = rule != nil
        colorWell.isEnabled = rule != nil
        maskField.stringValue = rule?.mask ?? ""
        colorWell.color = rule.flatMap { NSColor(hex: $0.color) } ?? .labelColor
    }

    @objc private func add(_ sender: Any?) {
        rules.append(ColorSettings.Rule(mask: "*.*", color: "#C0392B"))
        save(selecting: rules.count - 1)
        window?.makeFirstResponder(maskField)
    }

    @objc private func remove(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        rules.remove(at: index)
        save(selecting: min(index, rules.count - 1))
    }

    @objc private func addExamples(_ sender: Any?) {
        rules += ColorSettings.exampleRules.filter { !rules.contains($0) }
        save(selecting: rules.count - 1)
    }

    @objc private func formChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        rules[index].mask = maskField.stringValue
        rules[index].color = colorWell.color.hexString ?? rules[index].color
        ColorSettings.rules = rules
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }
}

extension FileColorsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        formChanged(nil)
    }
}

extension FileColorsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rules.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        rules[row].mask
    }

    /// Each mask is shown in its color.
    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        (cell as? NSTextFieldCell)?.textColor = NSColor(hex: rules[row].color) ?? .labelColor
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateForm()
    }
}
