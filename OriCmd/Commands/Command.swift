import AppKit

/// Commands named after their Total Commander counterparts (`cm_*`).
///
/// Each command is an Objective-C action (`cm_Copy:`) sent through the
/// responder chain, so menus, the function key bar and keyboard shortcuts
/// all dispatch the same way and can be validated with `NSMenuItemValidation`.
/// The main view controller forwards panel commands to the active panel,
/// so they work while the command line has focus too.
enum Command: String, CaseIterable {
    // Files
    case list = "cm_List"
    case edit = "cm_Edit"
    case copy = "cm_Copy"
    case renMov = "cm_RenMov"
    case renameOnly = "cm_RenameOnly"
    case mkDir = "cm_MkDir"
    case delete = "cm_Delete"
    case deletePermanently = "cm_DeletePermanently"
    case exit = "cm_Exit"

    // Mark
    case spreadSelection = "cm_SpreadSelection"
    case shrinkSelection = "cm_ShrinkSelection"
    case clearAll = "cm_ClearAll"
    case exchangeSelection = "cm_ExchangeSelection"

    // Commands
    case rereadSource = "cm_RereadSource"
    case exchange = "cm_Exchange"
    case goToRoot = "cm_GoToRoot"
    case goToParent = "cm_GoToParent"

    // Show
    case srcQuickView = "cm_SrcQuickview"
    case sortByName = "cm_SrcByName"
    case sortByExt = "cm_SrcByExt"
    case sortByDateTime = "cm_SrcByDateTime"
    case sortBySize = "cm_SrcBySize"
    case reverseOrder = "cm_SrcNegOrder"
    case switchHidSys = "cm_SwitchHidSys"

    init?(selector: Selector) {
        self.init(rawValue: String(NSStringFromSelector(selector).dropLast()))
    }

    var selector: Selector { Selector(rawValue + ":") }

    var title: String {
        switch self {
        case .list: "View"
        case .edit: "Edit"
        case .copy: "Copy…"
        case .renMov: "Move/Rename…"
        case .renameOnly: "Rename"
        case .mkDir: "New Folder…"
        case .delete: "Delete"
        case .deletePermanently: "Delete Permanently"
        case .exit: "Exit"
        case .spreadSelection: "Select Group…  (+)"
        case .shrinkSelection: "Unselect Group…  (−)"
        case .clearAll: "Unselect All"
        case .exchangeSelection: "Invert Selection  (*)"
        case .rereadSource: "Refresh"
        case .exchange: "Swap Panels"
        case .goToRoot: "Go to Root"
        case .goToParent: "Go to Parent"
        case .srcQuickView: "Quick View"
        case .sortByName: "Sort by Name"
        case .sortByExt: "Sort by Extension"
        case .sortByDateTime: "Sort by Date"
        case .sortBySize: "Sort by Size"
        case .reverseOrder: "Reverse Order"
        case .switchHidSys: "Show Hidden Files"
        }
    }

    /// The Total Commander key, shown in the menu. Keys that edit text
    /// (Del, Backspace, arrows) are handled by the file list instead.
    var shortcut: Shortcut? {
        switch self {
        case .list: .f(3)
        case .edit: .f(4)
        case .copy: .f(5)
        case .renMov: .f(6)
        case .renameOnly: .f(6, .shift)
        case .mkDir: .f(7)
        case .delete: .f(8)
        case .deletePermanently: .f(8, .shift)
        case .clearAll: .cmd("a", .option)
        case .rereadSource: .cmd("r")
        case .exchange: .ctrl("u")
        case .goToRoot: .ctrl("\\")
        case .srcQuickView: .ctrl("q")
        case .sortByName: .f(3, .control)
        case .sortByExt: .f(4, .control)
        case .sortByDateTime: .f(5, .control)
        case .sortBySize: .f(6, .control)
        case .switchHidSys: .cmd(".", .shift)
        default: nil
        }
    }

    /// Additional keys: Total Commander's Ctrl variants and Finder habits.
    var aliases: [Shortcut] {
        switch self {
        case .mkDir: [.cmd("n", .shift)]
        case .rereadSource: [.ctrl("r")]
        case .sortByName: [.cmd("1", [.control, .option])]
        case .sortByExt: [.cmd("2", [.control, .option])]
        case .sortByDateTime: [.cmd("3", [.control, .option])]
        case .sortBySize: [.cmd("4", [.control, .option])]
        default: []
        }
    }

    /// Sends the command to the first responder that implements it.
    @discardableResult
    func send(from sender: Any?) -> Bool {
        let handled = NSApp.sendAction(selector, to: nil, from: sender)
        if !handled { NSSound.beep() }
        return handled
    }
}
