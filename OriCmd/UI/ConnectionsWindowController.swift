import AppKit

/// Net → Connections (Total Commander's "FTP Connect", Ctrl+F): saved SFTP and
/// FTP servers, with passwords optionally kept in the Keychain.
final class ConnectionsWindowController: NSWindowController {
    static let shared = ConnectionsWindowController()

    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let addressField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let rememberBox = NSButton(checkboxWithTitle: String(localized: "Remember password in Keychain"),
                                       target: nil, action: nil)
    private var connections: [SavedConnection] = []
    private var onConnect: ((URL, String?) -> Void)?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Connections")
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `connect` receives the address and the saved password (if any).
    func show(connect: @escaping (URL, String?) -> Void) {
        onConnect = connect
        connections = Connections.all
        table.reloadData()
        if !connections.isEmpty && table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateForm()
        showWindow(nil)
    }

    private func buildContent() {
        for (identifier, title, width) in [("name", String(localized: "Title"), 180.0),
                                          ("address", String(localized: "Address"), 360.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connect(_:))
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        addressField.placeholderString = "sftp://user@host/path, ftp://user@host:21/"
        let form = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Title:")), nameField],
            [NSTextField(labelWithString: String(localized: "Address:")), addressField],
            [NSTextField(labelWithString: String(localized: "Password:")), passwordField],
            [NSGridCell.emptyContentView, rememberBox],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 8

        let connectButton = NSButton(title: String(localized: "Connect"), target: self, action: #selector(connect(_:)))
        connectButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [
            NSButton(title: String(localized: "New"), target: self, action: #selector(add(_:))),
            NSButton(title: String(localized: "Remove"), target: self, action: #selector(remove(_:))),
            NSButton(title: String(localized: "Save"), target: self, action: #selector(save(_:))),
            connectButton,
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
        connections.indices.contains(table.selectedRow) ? table.selectedRow : nil
    }

    private func updateForm() {
        let connection = selectedIndex.map { connections[$0] }
        nameField.stringValue = connection?.name ?? ""
        addressField.stringValue = connection?.address ?? ""
        passwordField.stringValue = connection.flatMap { $0.remembersPassword ? Credentials.password(for: $0.id) : nil } ?? ""
        rememberBox.state = connection?.remembersPassword == true ? .on : .off
    }

    @objc private func add(_ sender: Any?) {
        connections.append(SavedConnection(name: String(localized: "New Connection"), address: "sftp://"))
        Connections.all = connections
        table.reloadData()
        table.selectRowIndexes([connections.count - 1], byExtendingSelection: false)
        updateForm()
        window?.makeFirstResponder(nameField)
    }

    @objc private func remove(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        Credentials.setPassword(nil, for: connections[index].id)
        connections.remove(at: index)
        Connections.all = connections
        table.reloadData()
        updateForm()
    }

    /// Saves the form (and the password, when it is to be remembered).
    @objc private func save(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        connections[index].name = nameField.stringValue
        connections[index].address = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        connections[index].remembersPassword = rememberBox.state == .on
        Credentials.setPassword(rememberBox.state == .on ? passwordField.stringValue : nil, for: connections[index].id)
        Connections.all = connections
        table.reloadData(forRowIndexes: [index], columnIndexes: [0, 1])
    }

    @objc private func connect(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        save(nil)
        let connection = connections[index]
        guard let url = URL(string: connection.address), url.scheme != nil else {
            NSSound.beep()
            return
        }
        let typed = passwordField.stringValue
        let password = connection.remembersPassword ? Credentials.password(for: connection.id)
            : (typed.isEmpty ? nil : typed)
        window?.close()
        onConnect?(url, password)
    }
}

extension ConnectionsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        connections.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        tableColumn?.identifier.rawValue == "name" ? connections[row].name : connections[row].address
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateForm()
    }
}
