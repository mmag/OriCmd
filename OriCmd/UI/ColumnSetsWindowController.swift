import AppKit

/// Show → Columns → Column Sets…: Total Commander's custom columns. The Default
/// view and named sets, each with its columns; a set can be used by itself in the
/// folders matching its masks. Changes apply at once.
final class ColumnSetsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                        NSTextFieldDelegate {
    private static var shared: ColumnSetsWindowController?

    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let foldersField = NSTextField(string: "")
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let columnBoxes: [(SortColumn, NSButton)] = SortColumn.optional.map { column in
        (column, NSButton(checkboxWithTitle: FileListHeaderView.titles[column] ?? "", target: nil, action: nil))
    }
    private var sets = ColumnSet.saved

    static func show() {
        let controller = shared ?? ColumnSetsWindowController()
        shared = controller
        controller.sets = ColumnSet.saved
        controller.table.reloadData()
        controller.select(0)
        controller.showWindow(nil)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Column Sets")
        window.center()
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = String(localized: "Column set")
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let add = NSButton(title: "+", target: self, action: #selector(addSet(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeSet(_:))
        for button in [add, removeButton] {
            button.bezelStyle = .smallSquare
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let left = NSStackView(views: [scroll, NSStackView(views: [add, removeButton])])
        left.orientation = .vertical
        left.alignment = .leading

        for field in [nameField, foldersField] {
            field.delegate = self
            field.target = self
            field.action = #selector(fieldChanged(_:))
        }
        for (_, box) in columnBoxes {
            box.target = self
            box.action = #selector(columnsChanged(_:))
        }
        let boxes = NSGridView(views: stride(from: 0, to: columnBoxes.count, by: 3).map { start in
            (start..<min(start + 3, columnBoxes.count)).map { columnBoxes[$0].1 }
        })
        boxes.rowSpacing = 4
        boxes.columnSpacing = 16
        let hint = NSTextField(wrappingLabelWithString: String(localized:
            "Masks of folder paths, separated by ; (~/Pictures*;*/Photos): there the set is used by itself."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.preferredMaxLayoutWidth = 340
        let right = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Name:")), nameField],
            [NSTextField(labelWithString: String(localized: "Columns:")), boxes],
            [NSTextField(labelWithString: String(localized: "Use in folders:")), foldersField],
            [NSGridCell.emptyContentView, hint],
        ])
        right.column(at: 0).xPlacement = .trailing
        right.rowSpacing = 10
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let stack = NSStackView(views: [left, right])
        stack.alignment = .top
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window?.contentView = stack

        for (view, name) in [(table, "columnSetList"), (nameField, "columnSetName"), (foldersField, "columnSetFolders"),
                             (add, "columnSetAdd"), (removeButton, "columnSetRemove")] as [(NSView, String)] {
            view.identifier = NSUserInterfaceItemIdentifier(name)
        }
        for (column, box) in columnBoxes {
            box.identifier = NSUserInterfaceItemIdentifier("columnSet-\(column.rawValue)")
        }
    }

    /// Row 0 is the Default view, then the sets.
    private var row: Int { max(table.selectedRow, 0) }

    private func select(_ row: Int) {
        table.selectRowIndexes([min(max(row, 0), sets.count)], byExtendingSelection: false)
        showSelected()
    }

    private func showSelected() {
        let isDefault = row == 0
        let columns = isDefault ? ColumnSet.standard : sets[row - 1].columns
        nameField.stringValue = isDefault ? String(localized: "Default Columns") : sets[row - 1].name
        foldersField.stringValue = isDefault ? "" : sets[row - 1].folders
        nameField.isEnabled = !isDefault
        foldersField.isEnabled = !isDefault
        removeButton.isEnabled = !isDefault
        for (column, box) in columnBoxes {
            box.state = columns.contains(column) ? .on : .off
        }
    }

    private func save() {
        ColumnSet.saved = sets
    }

    @objc private func addSet(_ sender: Any?) {
        var number = sets.count + 1
        while sets.contains(where: { $0.name == String(localized: "Columns \(number)") }) { number += 1 }
        sets.append(ColumnSet(name: String(localized: "Columns \(number)"), columns: ColumnSet.standard, folders: ""))
        save()
        table.reloadData()
        select(sets.count)
        window?.makeFirstResponder(nameField)
    }

    @objc private func removeSet(_ sender: Any?) {
        guard row > 0 else { return }
        sets.remove(at: row - 1)
        save()
        table.reloadData()
        select(row - 1)
    }

    @objc private func columnsChanged(_ sender: Any?) {
        let columns = columnBoxes.filter { $0.1.state == .on }.map(\.0)
        if row == 0 {
            ColumnSet.setColumns(columns, of: "")
        } else {
            sets[row - 1].columns = columns
            save()
        }
    }

    /// A name taken by another set (or empty) is not used.
    @objc private func fieldChanged(_ sender: Any?) {
        guard row > 0 else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !sets.enumerated().contains(where: { $0.offset != row - 1 && $0.element.name == name }) {
            sets[row - 1].name = name
        }
        sets[row - 1].folders = foldersField.stringValue
        save()
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        fieldChanged(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sets.count + 1
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        row == 0 ? String(localized: "Default Columns") : sets[row - 1].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelected()
    }
}
