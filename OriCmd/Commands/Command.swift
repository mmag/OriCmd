import AppKit

/// Commands named after their Total Commander counterparts (`cm_*`).
///
/// Each command is an Objective-C action (`cm_Copy:`) sent through the
/// responder chain, so menus, the function key bar and keyboard shortcuts
/// all dispatch the same way and can be validated with `NSMenuItemValidation`.
enum Command: String, CaseIterable {
    case list = "cm_List"
    case edit = "cm_Edit"
    case copy = "cm_Copy"
    case renMov = "cm_RenMov"
    case mkDir = "cm_MkDir"
    case delete = "cm_Delete"
    case exit = "cm_Exit"

    var selector: Selector { Selector(rawValue + ":") }

    /// Sends the command to the first responder that implements it.
    @discardableResult
    func send(from sender: Any?) -> Bool {
        let handled = NSApp.sendAction(selector, to: nil, from: sender)
        if !handled { NSSound.beep() }
        return handled
    }
}
