import AppKit

/// Connect to Server, in the manner of the Finder's: the address, the recent servers
/// in a striped list under it (a click picks one, a double click connects, ↓ goes
/// from the address to the list), and the sheet can be made taller.
final class ServerAddressSheet: NSObject {
    private static let sizeKey = "ServerSheetSize"
    private static let minimumSize = NSSize(width: 460, height: 320)

    private let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: minimumSize),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private var addresses: [String]
    private let onRemove: (String) -> Void
    private let completion: (String) -> Void
    /// Kept while the sheet is shown (nothing else holds it).
    private static var shown: ServerAddressSheet?

    static func show(
        _ title: String,
        message: String,
        initial: String,
        recent: [String],
        okTitle: String,
        in window: NSWindow,
        onRemove: @escaping (String) -> Void,
        completion: @escaping (String) -> Void
    ) {
        let controller = ServerAddressSheet(recent: recent, onRemove: onRemove, completion: completion)
        controller.build(title: title, message: message, initial: initial, okTitle: okTitle)
        shown = controller
        window.beginSheet(controller.sheet) { response in
            if let size = controller.sheet.contentView?.bounds.size {
                AppDefaults.store.set(NSStringFromSize(size), forKey: sizeKey)
            }
            shown = nil
            if response == .OK {
                controller.completion(controller.field.stringValue)
            }
        }
        controller.field.currentEditor()?.selectedRange = NSRange(location: 0, length: (initial as NSString).length)
    }

    private init(recent: [String], onRemove: @escaping (String) -> Void, completion: @escaping (String) -> Void) {
        addresses = recent
        self.onRemove = onRemove
        self.completion = completion
        super.init()
    }

    private func build(title: String, message: String, initial: String, okTitle: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor

        field.stringValue = initial
        field.delegate = self
        let recentLabel = NSTextField(labelWithString: String(localized: "Recent Servers:"))
        recentLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectToClicked(_:))
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Remove from List"), action: #selector(removeChosen(_:)), keyEquivalent: "")
            .target = self
        table.menu = menu
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeChosen(_:))
        removeButton.toolTip = String(localized: "Remove from List")
        removeButton.isEnabled = false
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let connect = NSButton(title: okTitle, target: self, action: #selector(connect(_:)))
        connect.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [removeButton, spacer, cancel, connect])

        let stack = NSStackView(views: [titleLabel, messageLabel, field, recentLabel, scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: field)
        stack.setCustomSpacing(14, after: scrollView)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for view in [messageLabel, field, scrollView, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 6 * 24 + 4).isActive = true
        sheet.contentView = stack
        sheet.contentMinSize = Self.minimumSize
        sheet.defaultButtonCell = connect.cell as? NSButtonCell
        sheet.initialFirstResponder = field
        if let saved = AppDefaults.store.string(forKey: Self.sizeKey) {
            let size = NSSizeFromString(saved)
            sheet.setContentSize(NSSize(width: max(size.width, Self.minimumSize.width),
                                        height: max(size.height, Self.minimumSize.height)))
        }
    }

    @objc private func connect(_ sender: Any?) {
        sheet.sheetParent?.endSheet(sheet, returnCode: .OK)
    }

    @objc private func cancel(_ sender: Any?) {
        sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
    }

    @objc private func connectToClicked(_ sender: Any?) {
        guard addresses.indices.contains(table.clickedRow) else { return }
        field.stringValue = addresses[table.clickedRow]
        connect(sender)
    }

    @objc private func removeChosen(_ sender: Any?) {
        let row = sender is NSMenuItem && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard addresses.indices.contains(row) else { return }
        onRemove(addresses.remove(at: row))
        table.reloadData()
        table.deselectAll(nil)
        removeButton.isEnabled = false
    }
}

extension ServerAddressSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        addresses.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("address"), owner: self)
            as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = addresses[row]
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("address")
        let icon = NSImageView(image: NSImage(named: NSImage.networkName) ?? NSImage())
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for view in [icon, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = icon
        cell.textField = text
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A chosen address goes into the field.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        removeButton.isEnabled = addresses.indices.contains(row)
        guard addresses.indices.contains(row) else { return }
        field.stringValue = addresses[row]
    }
}

extension ServerAddressSheet: NSTextFieldDelegate {
    /// ↓ in the address goes to the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), !addresses.isEmpty else { return false }
        sheet.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        return true
    }
}
