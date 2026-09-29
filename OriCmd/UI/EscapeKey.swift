import AppKit

/// A window that handles Esc itself (the Lister closes its find bar first).
protocol HandlesEscapeKey {}

/// Esc closes any dialog, as in Total Commander: a sheet or modal dialog in front
/// is cancelled, any other window is closed. The main window keeps Esc for its own
/// uses (quick search, the command line, the server terminal).
enum EscapeKey {
    /// Buttons Esc presses in alerts where it means the default button (such as
    /// "Continue Working"), which cannot have two keys of its own.
    private static let answers = NSMapTable<NSWindow, NSButton>.weakToWeakObjects()

    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = NSApp.keyWindow, handle(event, in: window) else { return event }
            return nil
        }
    }

    /// Esc in `alert` answers with `button`.
    static func answer(_ alert: NSAlert, with button: NSButton) {
        answers.setObject(button, forKey: alert.window)
    }

    /// Handles Esc typed in `window`; false leaves the key to AppKit.
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(window is MainWindow), !(window is NSSavePanel),
              !(window.windowController is HandlesEscapeKey) else { return false }
        // A drop-down list or completions shown: Esc closes them first.
        if window.childWindows?.contains(where: \.isVisible) == true { return false }
        if let editor = window.firstResponder as? NSTextView {
            // Text being composed (an input method), or a search field that clears first.
            if editor.hasMarkedText() { return false }
            if let search = editor.delegate as? NSSearchField, !search.stringValue.isEmpty { return false }
            // A cell of a table being edited: Esc cancels the edit.
            if let field = editor.delegate as? NSView, field.enclosingTableView != nil { return false }
        }
        if window.firstResponder is TakesEscapeKey { return false }

        if let button = answers.object(forKey: window) ?? cancelButton(in: window.contentView) {
            button.performClick(nil)
            return true
        }
        if window.sheetParent != nil || NSApp.modalWindow === window {
            // An alert with a single button (OK): Esc dismisses it too.
            let buttons = pushButtons(in: window.contentView)
            guard buttons.count == 1 else { return false }
            buttons[0].performClick(nil)
            return true
        }
        guard window.styleMask.contains(.closable) else { return false }
        window.performClose(nil)
        return true
    }

    /// The enabled button whose key is Esc (Cancel).
    private static func cancelButton(in view: NSView?) -> NSButton? {
        buttons(in: view).first { $0.keyEquivalent == "\u{1b}" }
    }

    /// Buttons with a frame and a title: not checkboxes, radio or help buttons.
    private static func pushButtons(in view: NSView?) -> [NSButton] {
        buttons(in: view).filter { $0.isBordered && !$0.title.isEmpty }
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view, !view.isHidden else { return [] }
        if let button = view as? NSButton {
            return button.isEnabled ? [button] : []
        }
        return view.subviews.flatMap(buttons)
    }
}

/// A view that takes Esc itself while it has the focus (the shortcut recorder).
protocol TakesEscapeKey {}

extension NSAlert {
    /// Adds the Cancel button with Esc as its key: NSAlert gives Esc only to a
    /// button titled as AppKit's own "Cancel", which the Russian one is not.
    @discardableResult
    func addCancelButton(_ title: String = String(localized: "Cancel")) -> NSButton {
        let button = addButton(withTitle: title)
        button.keyEquivalent = "\u{1b}"
        return button
    }
}

private extension NSView {
    var enclosingTableView: NSTableView? {
        var view = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }
}
