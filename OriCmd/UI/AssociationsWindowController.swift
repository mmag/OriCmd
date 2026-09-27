import AppKit
import UniformTypeIdentifiers

/// "Internal Associations": programs for Enter, F3 and F4 by file mask.
final class AssociationsWindowController: NSWindowController {
    static let shared = AssociationsWindowController()

    private let table = NSTableView()
    private let maskField = NSTextField(string: "")
    private let openField = NSTextField(string: "")
    private let viewField = NSTextField(string: "")
    private let editField = NSTextField(string: "")
    private var chooseButtons: [NSButton] = []
    private var associations: [FileAssociation] = []

    private var programFields: [NSTextField] { [openField, viewField, editField] }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Internal Associations")
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        associations = FileAssociations.all
        table.reloadData()
        if !associations.isEmpty && table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateForm()
        super.showWindow(sender)
    }

    private func buildContent() {
        for (identifier, title, width) in [("mask", String(localized: "Mask"), 150.0),
                                          ("open", String(localized: "Open (Enter)"), 170.0),
                                          ("view", String(localized: "View (F3)"), 170.0),
                                          ("edit", String(localized: "Edit (F4)"), 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let listButtons = NSStackView(views: [
            NSButton(title: String(localized: "Add"), target: self, action: #selector(add(_:))),
            NSButton(title: String(localized: "Remove"), target: self, action: #selector(remove(_:))),
            NSButton(title: String(localized: "Move Up"), target: self, action: #selector(moveEntryUp(_:))),
            NSButton(title: String(localized: "Move Down"), target: self, action: #selector(moveEntryDown(_:))),
        ])

        maskField.delegate = self
        maskField.placeholderString = "*.swift;*.json"
        let placeholders = ["/Applications/Visual Studio Code.app", "qlmanage -p", "code -g %P%N"]
        var rows: [[NSView]] = [[NSTextField(labelWithString: String(localized: "Mask:")), maskField]]
        let labels = [String(localized: "Open (Enter):"), String(localized: "View (F3):"), String(localized: "Edit (F4):")]
        for (index, field) in programFields.enumerated() {
            field.delegate = self
            field.placeholderString = placeholders[index]
            let choose = NSButton(title: String(localized: "Application…"), target: self,
                                  action: #selector(chooseApplication(_:)))
            choose.tag = index
            chooseButtons.append(choose)
            let row = NSStackView(views: [field, choose])
            row.spacing = 6
            rows.append([NSTextField(labelWithString: labels[index]), row])
        }

        let help = NSTextField(wrappingLabelWithString: String(localized:
            "The first entry whose mask matches and that has a program for the key is used; empty fields fall back to the standard behaviour (the Lister for F3, the default text editor for F4, the macOS default app for Enter). A program is an application or a shell command: %P is the file's folder, %N its name; without them the quoted path is added at the end."))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        rows.append([NSGridCell.emptyContentView, help])

        let form = NSGridView(views: rows)
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        form.rowSpacing = 8

        let stack = NSStackView(views: [scrollView, listButtons, form])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scrollView, form] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        help.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    private var selectedIndex: Int? {
        associations.indices.contains(table.selectedRow) ? table.selectedRow : nil
    }

    private func save(selecting index: Int?) {
        FileAssociations.all = associations
        table.reloadData()
        if let index, associations.indices.contains(index) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateForm()
    }

    private func updateForm() {
        let association = selectedIndex.map { associations[$0] }
        for control in [maskField] + programFields + chooseButtons as [NSControl] {
            control.isEnabled = association != nil
        }
        maskField.stringValue = association?.mask ?? ""
        openField.stringValue = association?.open ?? ""
        viewField.stringValue = association?.view ?? ""
        editField.stringValue = association?.edit ?? ""
    }

    @objc private func add(_ sender: Any?) {
        associations.append(FileAssociation(mask: "*.txt"))
        save(selecting: associations.count - 1)
        window?.makeFirstResponder(maskField)
    }

    @objc private func remove(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        associations.remove(at: index)
        save(selecting: min(index, associations.count - 1))
    }

    @objc private func moveEntryUp(_ sender: Any?) {
        guard let index = selectedIndex, index > 0 else { return }
        associations.swapAt(index, index - 1)
        save(selecting: index - 1)
    }

    @objc private func moveEntryDown(_ sender: Any?) {
        guard let index = selectedIndex, index < associations.count - 1 else { return }
        associations.swapAt(index, index + 1)
        save(selecting: index + 1)
    }

    @objc private func chooseApplication(_ sender: NSButton) {
        guard let window, programFields.indices.contains(sender.tag) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            programFields[sender.tag].stringValue = url.path
            formChanged(nil)
        }
    }

    @objc private func formChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        associations[index].mask = maskField.stringValue
        associations[index].open = openField.stringValue
        associations[index].view = viewField.stringValue
        associations[index].edit = editField.stringValue
        FileAssociations.all = associations
        table.reloadData(forRowIndexes: [index], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }
}

extension AssociationsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        formChanged(nil)
    }
}

extension AssociationsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        associations.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let association = associations[row]
        let program = switch tableColumn?.identifier.rawValue {
        case "mask": association.mask
        case "open": association.open
        case "view": association.view
        default: association.edit
        }
        // Applications are shown by name.
        return FileAssociations.application(at: program).map {
            FileManager.default.displayName(atPath: $0.path)
        } ?? program
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateForm()
    }
}
