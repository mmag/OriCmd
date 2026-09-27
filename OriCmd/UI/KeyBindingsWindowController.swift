import AppKit
import UniformTypeIdentifiers

/// Settings → Keys: assigns keys to commands, like Total Commander's
/// "Redefine hotkeys", and imports them from wincmd.ini.
final class KeyBindingsWindowController: NSWindowController {
    static let shared = KeyBindingsWindowController()

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var commands: [Command] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Keyboard Shortcuts")
        super.init(window: window)
        buildContent()
        window.center()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent() {
        searchField.placeholderString = String(localized: "Search commands")
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        for (identifier, title, width) in [("title", String(localized: "Command"), 260.0),
                                          ("name", String(localized: "Name"), 200.0),
                                          ("keys", String(localized: "Keys"), 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(change(_:))
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let buttons = NSStackView(views: [
            NSButton(title: String(localized: "Change…"), target: self, action: #selector(change(_:))),
            NSButton(title: String(localized: "Clear"), target: self, action: #selector(clear(_:))),
            NSButton(title: String(localized: "Default"), target: self, action: #selector(resetSelected(_:))),
            NSButton(title: String(localized: "Reset All"), target: self, action: #selector(resetAll(_:))),
            NSButton(title: String(localized: "Import wincmd.ini…"), target: self, action: #selector(importIni(_:))),
        ])
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [searchField, scrollView, buttons, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [searchField, scrollView, statusLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    private func reload() {
        let query = searchField.stringValue
        commands = Command.allCases.filter { command in
            command != .exit && (query.isEmpty || command.title.localizedCaseInsensitiveContains(query)
                || command.rawValue.localizedCaseInsensitiveContains(query))
        }
        table.reloadData()
    }

    private var selectedCommand: Command? {
        commands.indices.contains(table.selectedRow) ? commands[table.selectedRow] : nil
    }

    @objc private func searchChanged(_ sender: Any?) {
        reload()
    }

    /// Records the next key combination for the selected command.
    @objc private func change(_ sender: Any?) {
        guard let command = selectedCommand, let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90), styleMask: [.titled],
                            backing: .buffered, defer: true)
        let recorder = ShortcutRecorder(frame: panel.contentView!.bounds)
        recorder.autoresizingMask = [.width, .height]
        recorder.prompt = String(localized: "Press the new keys for \u{201C}\(command.title)\u{201D} (Esc cancels)")
        recorder.onRecord = { [weak self] shortcut in
            window.endSheet(panel)
            guard let self, let shortcut else { return }
            let takenFrom = KeyBindings.set(shortcut, for: command)
            statusLabel.stringValue = takenFrom.isEmpty ? ""
                : String(localized: "Removed from: \(takenFrom.map(\.title).joined(separator: ", "))")
            reload()
        }
        panel.contentView?.addSubview(recorder)
        window.beginSheet(panel, completionHandler: nil)
        panel.makeFirstResponder(recorder)
    }

    @objc private func clear(_ sender: Any?) {
        guard let command = selectedCommand else { return }
        KeyBindings.set(nil, for: command)
        reload()
    }

    @objc private func resetSelected(_ sender: Any?) {
        guard let command = selectedCommand else { return }
        KeyBindings.reset(command)
        reload()
    }

    @objc private func resetAll(_ sender: Any?) {
        KeyBindings.resetAll()
        statusLabel.stringValue = ""
        reload()
    }

    @objc private func importIni(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose Total Commander's wincmd.ini")
        panel.allowedContentTypes = [UTType(filenameExtension: "ini") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let result = try KeyBindings.importTotalCommanderShortcuts(from: url)
                statusLabel.stringValue = String(localized:
                    "Imported \(result.imported) keys, skipped \(result.skipped.count)")
                reload()
            } catch {
                Prompt.error(String(localized: "Cannot read \u{201C}\(url.lastPathComponent)\u{201D}"), error, in: window)
            }
        }
    }
}

extension KeyBindingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let command = commands[row]
        switch tableColumn?.identifier.rawValue {
        case "title": return command.title
        case "name": return command.rawValue
        default:
            let keys = [command.shortcut].compactMap { $0 } + KeyBindings.extras(for: command)
            return keys.map(\.displayString).joined(separator: ", ")
        }
    }

    /// Changed keys are shown in bold.
    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let cell = cell as? NSTextFieldCell else { return }
        let custom = tableColumn?.identifier.rawValue == "keys" && KeyBindings.isCustomized(commands[row])
        cell.font = custom ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
    }
}

/// Captures one key combination, including ⌘ combinations that would
/// otherwise trigger menu items.
private final class ShortcutRecorder: NSView {
    var prompt = ""
    var onRecord: ((Shortcut?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && modifiers.isEmpty {
            onRecord?(nil)
        } else if let shortcut = Shortcut(event: event) {
            onRecord?(shortcut)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        (prompt as NSString).draw(in: bounds.insetBy(dx: 16, dy: 30), withAttributes: attributes)
    }
}
