import AppKit

/// Small modal sheets in the spirit of Total Commander's dialogs.
enum Prompt {
    /// Asks for a line of text; `selection` defaults to the whole initial text.
    static func text(
        _ title: String,
        message: String,
        initial: String = "",
        selection: NSRange? = nil,
        okTitle: String = String(localized: "OK"),
        in window: NSWindow,
        completion: @escaping (String) -> Void
    ) {
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 22)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue)
            }
        }
        let range = selection ?? NSRange(location: 0, length: (initial as NSString).length)
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = range
        }
    }

    /// Asks for a line of text, with an extra "Queue" button (F2) as in Total
    /// Commander's copy dialog; the completion learns which button was used.
    static func text(
        _ title: String,
        message: String,
        initial: String,
        okTitle: String,
        queueTitle: String,
        in window: NSWindow,
        completion: @escaping (_ text: String, _ queued: Bool) -> Void
    ) {
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 22)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        let queue = alert.addButton(withTitle: queueTitle)
        queue.keyEquivalent = String(UnicodeScalar(UInt32(NSF2FunctionKey))!)
        queue.keyEquivalentModifierMask = []
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: completion(field.stringValue, false)
            case .alertThirdButtonReturn: completion(field.stringValue, true)
            default: break
            }
        }
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (initial as NSString).length)
        }
    }

    /// Asks for a line of text plus a checkbox option.
    static func text(
        _ title: String,
        message: String,
        initial: String,
        option: String,
        optionIsOn: Bool,
        okTitle: String,
        in window: NSWindow,
        completion: @escaping (String, Bool) -> Void
    ) {
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 30, width: 360, height: 22)
        let checkbox = NSButton(checkboxWithTitle: option, target: nil, action: nil)
        checkbox.state = optionIsOn ? .on : .off
        checkbox.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
        accessory.addSubview(field)
        accessory.addSubview(checkbox)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessory
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue, checkbox.state == .on)
            }
        }
    }

    /// Asks for a server address, with the recent ones listed under the field: a click
    /// puts one into the field, a double click connects, ↓ goes from the field to the list.
    static func address(
        _ title: String,
        message: String,
        initial: String,
        recent: [String],
        okTitle: String,
        in window: NSWindow,
        onRemove: @escaping (String) -> Void,
        completion: @escaping (String) -> Void
    ) {
        let width: CGFloat = 400
        let field = NSTextField(string: initial)
        let list = RecentAddressList(addresses: recent, field: field, onRemove: onRemove)
        let listHeight: CGFloat = recent.isEmpty ? 0 : min(CGFloat(recent.count), 6) * 22 + 4
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22 + (recent.isEmpty ? 0 : 8 + listHeight)))
        field.frame = NSRect(x: 0, y: accessory.frame.height - 22, width: width, height: 22)
        field.delegate = list
        accessory.addSubview(field)
        if !recent.isEmpty {
            list.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
            accessory.addSubview(list.scrollView)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessory
        let ok = alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        list.onChoose = { ok.performClick(nil) }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            // The list lives as long as the sheet.
            withExtendedLifetime(list) {
                if response == .alertFirstButtonReturn {
                    completion(field.stringValue)
                }
            }
        }
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (initial as NSString).length)
        }
    }

    /// Asks for a password (hidden while typing).
    static func password(_ title: String, message: String, in window: NSWindow,
                         completion: @escaping (String) -> Void) {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addCancelButton()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue)
            }
        }
    }

    /// Asks to pick one of `options`; the completion gets its index.
    static func choice(
        _ title: String,
        message: String,
        options: [String],
        selected: Int = 0,
        okTitle: String,
        in window: NSWindow,
        completion: @escaping (Int) -> Void
    ) {
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        popUp.addItems(withTitles: options)
        popUp.selectItem(at: selected)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = popUp
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(popUp.indexOfSelectedItem)
            }
        }
    }

    static func confirm(
        _ title: String,
        message: String = "",
        okTitle: String,
        destructive: Bool = false,
        in window: NSWindow,
        completion: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let ok = alert.addButton(withTitle: okTitle)
        ok.hasDestructiveAction = destructive
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion()
            }
        }
        if destructive {
            // NSAlert never makes a destructive button the default one (and resets
            // key equivalents while laying out); Total Commander users expect Enter
            // to confirm anyway.
            ok.keyEquivalent = "\r"
        }
    }

    static func info(_ title: String, message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// A sheet with a spinner and Cancel (Esc; Return does not cancel) while something
    /// slow runs. Returns the function that closes it; `onCancel` runs on Cancel only.
    static func progress(_ title: String, in window: NSWindow, onCancel: @escaping () -> Void) -> () -> Void {
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = spinner
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { onCancel() }
        }
        return { [weak window] in
            guard let window, alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
    }

    static func error(_ title: String, _ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// The recent servers under the address field of Connect to Server.
private final class RecentAddressList: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let scrollView = NSScrollView()
    private let table = NSTableView()
    private var addresses: [String]
    private let field: NSTextField
    private let onRemove: (String) -> Void
    /// A double click (or Return in the list): connect to the chosen address.
    var onChoose: (() -> Void)?

    init(addresses: [String], field: NSTextField, onRemove: @escaping (String) -> Void) {
        self.addresses = addresses
        self.field = field
        self.onRemove = onRemove
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose(_:))
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Remove from List"), action: #selector(remove(_:)), keyEquivalent: "")
            .target = self
        table.menu = menu
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        addresses.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        addresses[row]
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }

    /// A chosen address goes into the field.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard addresses.indices.contains(table.selectedRow) else { return }
        field.stringValue = addresses[table.selectedRow]
    }

    @objc private func choose(_ sender: Any?) {
        guard addresses.indices.contains(table.clickedRow) else { return }
        field.stringValue = addresses[table.clickedRow]
        onChoose?()
    }

    @objc private func remove(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard addresses.indices.contains(row) else { return }
        onRemove(addresses.remove(at: row))
        table.reloadData()
    }

    /// ↓ in the field goes to the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), !addresses.isEmpty else { return false }
        control.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        return true
    }
}
