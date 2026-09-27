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
    case packFiles = "cm_PackFiles"
    case unpackFiles = "cm_UnpackFiles"
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
        case .list: String(localized: "View")
        case .edit: String(localized: "Edit")
        case .copy: String(localized: "Copy…")
        case .renMov: String(localized: "Move/Rename…")
        case .renameOnly: String(localized: "Rename")
        case .mkDir: String(localized: "New Folder…")
        case .delete: String(localized: "Delete")
        case .deletePermanently: String(localized: "Delete Permanently")
        case .packFiles: String(localized: "Pack…")
        case .unpackFiles: String(localized: "Unpack…")
        case .exit: String(localized: "Exit")
        case .spreadSelection: String(localized: "Select Group…  (+)")
        case .shrinkSelection: String(localized: "Unselect Group…  (−)")
        case .clearAll: String(localized: "Unselect All")
        case .exchangeSelection: String(localized: "Invert Selection  (*)")
        case .rereadSource: String(localized: "Refresh")
        case .exchange: String(localized: "Swap Panels")
        case .goToRoot: String(localized: "Go to Root")
        case .goToParent: String(localized: "Go to Parent")
        case .executeDOS: String(localized: "Open Terminal Here")
        case .goToPrevDir: String(localized: "Back")
        case .goToNextDir: String(localized: "Forward")
        case .directoryHistory: String(localized: "Folder History…")
        case .transferLeft: String(localized: "Show in Left Panel")
        case .transferRight: String(localized: "Show in Right Panel")
        case .leftOpenDrives: String(localized: "Left Volume List")
        case .rightOpenDrives: String(localized: "Right Volume List")
        case .openNewTab: String(localized: "New Tab")
        case .openDirInNewTab: String(localized: "Open Folder in New Tab")
        case .closeCurrentTab: String(localized: "Close Tab")
        case .switchToNextTab: String(localized: "Next Tab")
        case .switchToPreviousTab: String(localized: "Previous Tab")
        case .directoryHotlist: String(localized: "Directory Hotlist…")
        case .searchFor: String(localized: "Find Files…")
        case .srcShort: String(localized: "Brief")
        case .srcLong: String(localized: "Full")
        case .srcTree: String(localized: "Tree")
        case .srcQuickView: String(localized: "Quick View")
        case .sortByName: String(localized: "Sort by Name")
        case .sortByExt: String(localized: "Sort by Extension")
        case .sortByDateTime: String(localized: "Sort by Date")
        case .sortBySize: String(localized: "Sort by Size")
        case .reverseOrder: String(localized: "Reverse Order")
        case .switchHidSys: String(localized: "Show Hidden Files")
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
        case .packFiles: .f(5, .option)
        case .unpackFiles: .f(9, .option)
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
