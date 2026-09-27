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
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(field.stringValue, checkbox.state == .on)
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
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        alert.addButton(withTitle: String(localized: "Cancel"))
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
