import AppKit

/// "Change Start Menu": edits the user commands of the Start menu.
final class UserCommandsWindowController: NSWindowController {
    static let shared = UserCommandsWindowController()

    private let table = NSTableView()
    private let titleField = NSTextField(string: "")
    private let commandField = NSTextField(string: "")
    private let keysField = NSTextField(string: "")
    private let terminalBox = NSButton(checkboxWithTitle: String(localized: "Run in Terminal"), target: nil, action: nil)
    private var commands: [UserCommand] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Start Menu")
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        commands = UserCommands.all
        table.reloadData()
        if !commands.isEmpty && table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateForm()
        super.showWindow(sender)
    }

    private func buildContent() {
        for (identifier, title, width) in [("title", String(localized: "Title"), 180.0),
                                          ("command", String(localized: "Command"), 320.0),
                                          ("keys", String(localized: "Keys"), 90.0)] {
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

        for field in [titleField, commandField, keysField] {
            field.delegate = self
        }
        commandField.placeholderString = "open -a TextEdit %S"
        keysField.placeholderString = String(localized: "e.g. CM+E (C Control, A Option, S Shift, M Command)")
        terminalBox.target = self
        terminalBox.action = #selector(formChanged(_:))

        let help = NSTextField(wrappingLabelWithString: String(localized:
            "%P folder of the active panel, %N file under the cursor, %S selected files, %T folder of the other panel, %M file under the cursor there. Values are quoted for the shell."))
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        let form = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Title:")), titleField],
            [NSTextField(labelWithString: String(localized: "Command:")), commandField],
            [NSTextField(labelWithString: String(localized: "Keys:")), keysField],
            [NSGridCell.emptyContentView, terminalBox],
            [NSGridCell.emptyContentView, help],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 8

        let stack = NSStackView(views: [scrollView, listButtons, form])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scrollView, form] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        help.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    private var selectedIndex: Int? {
        commands.indices.contains(table.selectedRow) ? table.selectedRow : nil
    }

    private func save(selecting index: Int?) {
        UserCommands.all = commands
        table.reloadData()
        if let index, commands.indices.contains(index) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateForm()
    }

    private func updateForm() {
        let command = selectedIndex.map { commands[$0] }
        for field in [titleField, commandField, keysField] {
            field.isEnabled = command != nil
        }
        terminalBox.isEnabled = command != nil
        titleField.stringValue = command?.title ?? ""
        commandField.stringValue = command?.command ?? ""
        keysField.stringValue = command?.keys ?? ""
        terminalBox.state = command?.runsInTerminal == true ? .on : .off
    }

    @objc private func add(_ sender: Any?) {
        commands.append(UserCommand(title: String(localized: "New Command"), command: ""))
        save(selecting: commands.count - 1)
        window?.makeFirstResponder(titleField)
    }

    @objc private func remove(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        commands.remove(at: index)
        save(selecting: min(index, commands.count - 1))
    }

    @objc private func moveEntryUp(_ sender: Any?) {
        guard let index = selectedIndex, index > 0 else { return }
        commands.swapAt(index, index - 1)
        save(selecting: index - 1)
    }

    @objc private func moveEntryDown(_ sender: Any?) {
        guard let index = selectedIndex, index < commands.count - 1 else { return }
        commands.swapAt(index, index + 1)
        save(selecting: index + 1)
    }

    @objc private func formChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        commands[index].title = titleField.stringValue
        commands[index].command = commandField.stringValue
        commands[index].keys = keysField.stringValue
        commands[index].runsInTerminal = terminalBox.state == .on
        UserCommands.all = commands
        table.reloadData(forRowIndexes: [index], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }
}

extension UserCommandsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        formChanged(nil)
    }
}

extension UserCommandsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch tableColumn?.identifier.rawValue {
        case "title": commands[row].title
        case "command": commands[row].command
        default: Shortcut(text: commands[row].keys)?.displayString ?? ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateForm()
    }
}
