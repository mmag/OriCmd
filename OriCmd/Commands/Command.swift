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
    case multiRenameFiles = "cm_MultiRenameFiles"
    case editNewFile = "cm_EditNewFile"
    case copySamePanel = "cm_CopySamepanel"
    case countDirContent = "cm_CountDirContent"
    case setAttrib = "cm_SetAttrib"
    case properties = "cm_Properties"
    case compareFilesByContent = "cm_CompareFilesByContent"
    case createSymlink = "cm_CreateSymlink"
    case commentFiles = "cm_CommentFiles"
    case createHardLink = "cm_CreateHardLink"
    case crcCreate = "cm_CRCcreate"
    case crcCheck = "cm_CRCcheck"
    case internalAssociate = "cm_InternalAssociate"
    case packFiles = "cm_PackFiles"
    case unpackFiles = "cm_UnpackFiles"
    case testArchive = "cm_TestArchive"
    case exit = "cm_Exit"

    // Mark
    case spreadSelection = "cm_SpreadSelection"
    case shrinkSelection = "cm_ShrinkSelection"
    case clearAll = "cm_ClearAll"
    case restoreSelection = "cm_RestoreSelection"
    case selectCurrentExtension = "cm_SelectCurrentExtension"
    case unselectCurrentExtension = "cm_UnselectCurrentExtension"
    case copyNamesToClip = "cm_CopyNamesToClip"
    case copyFullNamesToClip = "cm_CopyFullNamesToClip"
    case exchangeSelection = "cm_ExchangeSelection"
    case copyDetailsToClip = "cm_CopyDetailsToClip"
    case copyFullDetailsToClip = "cm_CopyFullDetailsToClip"
    case saveSelectionToFile = "cm_SaveSelectionToFile"
    case loadSelectionFromFile = "cm_LoadSelectionFromFile"
    case loadSelectionFromClip = "cm_LoadSelectionFromClip"

    // Commands
    case rereadSource = "cm_RereadSource"
    case exchange = "cm_Exchange"
    case leftEqualRight = "cm_LeftEqualRight"
    case rightEqualLeft = "cm_RightEqualLeft"
    case goToRoot = "cm_GoToRoot"
    case goToParent = "cm_GoToParent"
    case executeDOS = "cm_ExecuteDOS"
    case ftpDisconnect = "cm_FtpDisconnect"
    case ftpConnect = "cm_FtpConnect"
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
    case toggleLockCurrentTab = "cm_ToggleLockCurrentTab"
    case toggleLockDcaCurrentTab = "cm_ToggleLockDcaCurrentTab"
    case directoryHotlist = "cm_DirectoryHotlist"
    case searchFor = "cm_SearchFor"
    case compareDirs = "cm_CompareDirs"
    case syncDirs = "cm_SyncDirs"
    case syncChangeDir = "cm_SyncChangeDir"

    // Show
    case branchView = "cm_BranchView"
    case quickFilter = "cm_QuickFilter"
    case srcAllFiles = "cm_SrcAllFiles"
    case srcUserSpec = "cm_SrcUserSpec"
    case showOnlySelected = "cm_ShowOnlySelected"
    case srcShort = "cm_SrcShort"
    case srcLong = "cm_SrcLong"
    case srcThumbs = "cm_SrcThumbs"
    case srcTree = "cm_SrcTree"
    case cdTree = "cm_CDtree"
    case toggleSeparateTree1 = "cm_ToggleSeparateTree1"
    case horizontalPanels = "cm_HorizontalPanels"
    case srcQuickView = "cm_SrcQuickview"
    case sortByName = "cm_SrcByName"
    case sortByExt = "cm_SrcByExt"
    case sortByDateTime = "cm_SrcByDateTime"
    case sortBySize = "cm_SrcBySize"
    case reverseOrder = "cm_SrcNegOrder"
    case unsorted = "cm_SrcUnsorted"
    case switchHidSys = "cm_SwitchHidSys"
    case switchIgnoreList = "cm_SwitchIgnoreList"

    // The terminal of a server under the panel (OriCmd's own)
    case serverTerminal = "cm_ServerTerminal"
    case terminalChangeDir = "cm_TerminalChangeDir"

    /// Commands whose keys work while the terminal has the focus.
    static let terminalCommands: [Command] = [.serverTerminal, .terminalChangeDir]

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
        case .multiRenameFiles: String(localized: "Multi-Rename Tool…")
        case .editNewFile: String(localized: "Edit New File…")
        case .copySamePanel: String(localized: "Copy in Same Folder…")
        case .countDirContent: String(localized: "Calculate Folder Sizes")
        case .setAttrib: String(localized: "Change Attributes…")
        case .properties: String(localized: "Get Info")
        case .compareFilesByContent: String(localized: "Compare by Content")
        case .createSymlink: String(localized: "Create Symbolic Link…")
        case .commentFiles: String(localized: "Edit Comment…")
        case .createHardLink: String(localized: "Create Hard Link…")
        case .crcCreate: String(localized: "Create Checksum File…")
        case .crcCheck: String(localized: "Verify Checksums")
        case .internalAssociate: String(localized: "Internal Associations…")
        case .packFiles: String(localized: "Pack…")
        case .unpackFiles: String(localized: "Unpack…")
        case .testArchive: String(localized: "Test Archives")
        case .exit: String(localized: "Exit")
        case .spreadSelection: String(localized: "Select Group…  (+)")
        case .shrinkSelection: String(localized: "Unselect Group…  (−)")
        case .clearAll: String(localized: "Unselect All")
        case .restoreSelection: String(localized: "Restore Selection  (/)")
        case .selectCurrentExtension: String(localized: "Select Same Extension  (⌥+)")
        case .unselectCurrentExtension: String(localized: "Unselect Same Extension  (⌥−)")
        case .copyNamesToClip: String(localized: "Copy Names")
        case .copyFullNamesToClip: String(localized: "Copy Full Paths")
        case .copyDetailsToClip: String(localized: "Copy Names with Details")
        case .copyFullDetailsToClip: String(localized: "Copy Full Paths with Details")
        case .saveSelectionToFile: String(localized: "Save Selection to File…")
        case .loadSelectionFromFile: String(localized: "Load Selection from File…")
        case .loadSelectionFromClip: String(localized: "Load Selection from Clipboard")
        case .exchangeSelection: String(localized: "Invert Selection  (*)")
        case .rereadSource: String(localized: "Refresh")
        case .exchange: String(localized: "Swap Panels")
        case .leftEqualRight: String(localized: "Left = Right")
        case .rightEqualLeft: String(localized: "Right = Left")
        case .goToRoot: String(localized: "Go to Root")
        case .goToParent: String(localized: "Go to Parent")
        case .executeDOS: String(localized: "Open Terminal Here")
        case .ftpDisconnect: String(localized: "Disconnect")
        case .ftpConnect: String(localized: "Connections…")
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
        case .toggleLockCurrentTab: String(localized: "Lock Tab")
        case .toggleLockDcaCurrentTab: String(localized: "Lock Tab, Allow Folder Changes")
        case .directoryHotlist: String(localized: "Directory Hotlist…")
        case .searchFor: String(localized: "Find Files…")
        case .compareDirs: String(localized: "Compare Directories")
        case .syncDirs: String(localized: "Synchronize Directories…")
        case .syncChangeDir: String(localized: "Synchronous Directory Changes")
        case .branchView: String(localized: "Branch View (All Files in Subfolders)")
        case .quickFilter: String(localized: "Quick Filter…")
        case .srcAllFiles: String(localized: "All Files")
        case .srcUserSpec: String(localized: "Filter…")
        case .showOnlySelected: String(localized: "Only Selected Files")
        case .srcShort: String(localized: "Brief")
        case .srcLong: String(localized: "Full")
        case .srcThumbs: String(localized: "Thumbnails")
        case .srcTree: String(localized: "Tree")
        case .cdTree: String(localized: "Go to Folder in Tree…")
        case .toggleSeparateTree1: String(localized: "Separate Tree")
        case .horizontalPanels: String(localized: "Horizontal Panels")
        case .srcQuickView: String(localized: "Quick View")
        case .sortByName: String(localized: "Sort by Name")
        case .sortByExt: String(localized: "Sort by Extension")
        case .sortByDateTime: String(localized: "Sort by Date")
        case .sortBySize: String(localized: "Sort by Size")
        case .reverseOrder: String(localized: "Reverse Order")
        case .unsorted: String(localized: "Unsorted")
        case .switchHidSys: String(localized: "Show Hidden Files")
        case .switchIgnoreList: String(localized: "Use the Ignore List")
        case .serverTerminal: String(localized: "Server Terminal")
        case .terminalChangeDir: String(localized: "Terminal: Go to Panel Folder")
        }
    }

    /// The key shown in the menu: the user's own binding (Settings → Keys),
    /// or the default one.
    var shortcut: Shortcut? {
        KeyBindings.shortcut(for: self)
    }

    /// The Total Commander key, shown in the menu. Keys that edit text
    /// (Del, Backspace, arrows) are handled by the file list instead.
    var defaultShortcut: Shortcut? {
        switch self {
        case .list: .f(3)
        case .edit: .f(4)
        case .copy: .f(5)
        case .renMov: .f(6)
        case .renameOnly: .f(6, .shift)
        case .mkDir: .f(7)
        case .delete: .f(8)
        case .deletePermanently: .f(8, .shift)
        case .multiRenameFiles: .ctrl("m")
        case .editNewFile: .f(4, .shift)
        case .copySamePanel: .f(5, .shift)
        case .countDirContent: Shortcut("\r", [.option, .shift])
        case .setAttrib: .cmd("i")
        case .properties: Shortcut("\r", [.option])
        case .createSymlink: .f(5, [.control, .shift])
        case .commentFiles: .ctrl("z")
        case .packFiles: .f(5, .option)
        case .unpackFiles: .f(9, .option)
        case .testArchive: .f(9, [.option, .shift])
        case .clearAll: .cmd("a", .option)
        case .copyFullNamesToClip: .cmd("c", .option)
        case .rereadSource: .cmd("r")
        case .exchange: .ctrl("u")
        case .goToRoot: .ctrl("\\")
        case .srcQuickView: .ctrl("q")
        case .sortByName: .f(3, .control)
        case .sortByExt: .f(4, .control)
        case .sortByDateTime: .f(5, .control)
        case .sortBySize: .f(6, .control)
        case .unsorted: .f(7, .control)
        case .cdTree: .f(10, .option)
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
        case .compareDirs: .f(2, .shift)
        case .branchView: .cmd("b")
        case .quickFilter: .ctrl("s")
        case .ftpConnect: .cmd("k", .shift)
        case .srcShort: .cmd("1")
        case .srcLong: .cmd("2")
        case .srcTree: .cmd("3")
        case .srcThumbs: .cmd("4")
        case .serverTerminal: .ctrl("`")
        case .terminalChangeDir: .ctrl("`", .option)
        default: nil
        }
    }

    /// Additional keys: Total Commander's Ctrl variants and Finder habits.
    var aliases: [Shortcut] {
        switch self {
        case .mkDir: [.cmd("n", .shift)]
        // Total Commander's "F2 = rename" option, as in Windows Explorer.
        case .renameOnly: [.f(2)]
        case .rereadSource: [.ctrl("r")]
        case .sortByName: [.cmd("1", [.control, .option])]
        case .sortByExt: [.cmd("2", [.control, .option])]
        case .sortByDateTime: [.cmd("3", [.control, .option])]
        case .sortBySize: [.cmd("4", [.control, .option])]
        case .unsorted: [.cmd("5", [.control, .option])]
        case .switchToNextTab: [.cmd("}")]
        case .switchToPreviousTab: [.cmd("{")]
        case .searchFor: [.cmd("f")]
        case .srcShort: [.f(1, .control)]
        case .srcLong: [.f(2, .control)]
        case .srcTree: [.f(8, .control)]
        case .srcThumbs: [.f(1, [.control, .shift])]
        // The key under Esc of ISO keyboards ("§", "ё" on Russian – PC), where others have "`".
        case .serverTerminal: [.ctrl("§")]
        case .terminalChangeDir: [.ctrl("§", .option)]
        default: []
        }
    }

    /// Whether `event` is one of the command's keys (main, alias or the user's extra).
    func matches(_ event: NSEvent) -> Bool {
        guard let pressed = Shortcut(event: event) else { return false }
        return ([shortcut].compactMap { $0 } + aliases + KeyBindings.extras(for: self)).contains(pressed)
    }

    /// Sends the command to the first responder that implements it.
    @discardableResult
    func send(from sender: Any?) -> Bool {
        let handled = NSApp.sendAction(selector, to: nil, from: sender)
        if !handled { NSSound.beep() }
        return handled
    }
}
