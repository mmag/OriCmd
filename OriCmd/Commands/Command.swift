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
    case executeDOS = "cm_ExecuteDOS"
    case goToPrevDir = "cm_GoToPrevDir"
    case goToNextDir = "cm_GoToNextDir"
    case directoryHistory = "cm_DirectoryHistory"
    case transferLeft = "cm_TransferLeft"
    case transferRight = "cm_TransferRight"
    case leftOpenDrives = "cm_LeftOpenDrives"
    case rightOpenDrives = "cm_RightOpenDrives"
    case openNewTab = "cm_OpenNewTab"
    case openDirInNewTab = "cm_OpenDirInNewTab"
    case closeCurrentTab = "cm_CloseCurrentTab"
    case switchToNextTab = "cm_SwitchToNextTab"
    case switchToPreviousTab = "cm_SwitchToPreviousTab"
    case directoryHotlist = "cm_DirectoryHotlist"
    case searchFor = "cm_SearchFor"

    // Show
    case srcShort = "cm_SrcShort"
    case srcLong = "cm_SrcLong"
    case srcTree = "cm_SrcTree"
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
        case .executeDOS: "Open Terminal Here"
        case .goToPrevDir: "Back"
        case .goToNextDir: "Forward"
        case .directoryHistory: "Folder History…"
        case .transferLeft: "Show in Left Panel"
        case .transferRight: "Show in Right Panel"
        case .leftOpenDrives: "Left Volume List"
        case .rightOpenDrives: "Right Volume List"
        case .openNewTab: "New Tab"
        case .openDirInNewTab: "Open Folder in New Tab"
        case .closeCurrentTab: "Close Tab"
        case .switchToNextTab: "Next Tab"
        case .switchToPreviousTab: "Previous Tab"
        case .directoryHotlist: "Directory Hotlist…"
        case .searchFor: "Find Files…"
        case .srcShort: "Brief"
        case .srcLong: "Full"
        case .srcTree: "Tree"
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
        case .goToPrevDir: .cmd("[")
        case .goToNextDir: .cmd("]")
        case .leftOpenDrives: .f(1, .option)
        case .rightOpenDrives: .f(2, .option)
        case .openNewTab: .cmd("t")
        case .closeCurrentTab: .cmd("w")
        case .switchToNextTab: .ctrl("\t")
        case .switchToPreviousTab: .ctrl("\t", .shift)
        case .directoryHotlist: .cmd("d")
        case .searchFor: .f(7, .option)
        case .srcShort: .cmd("1")
        case .srcLong: .cmd("2")
        case .srcTree: .cmd("3")
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
        case .switchToNextTab: [.cmd("}")]
        case .switchToPreviousTab: [.cmd("{")]
        case .searchFor: [.cmd("f")]
        case .srcShort: [.f(1, .control)]
        case .srcLong: [.f(2, .control)]
        case .srcTree: [.f(8, .control)]
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
