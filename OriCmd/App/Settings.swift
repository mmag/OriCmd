import AppKit

/// User preferences (see the Settings window). Changes post `didChange`.
enum Settings {
    static let didChange = Notification.Name("OriCmdSettingsDidChange")

    /// How typed letters are used in a panel, as in Total Commander's options.
    enum QuickSearchMode: String {
        /// Option+letters search; plain letters go to the command line (TC default).
        case optionLetters
        /// Plain letters search; Option+letters go to the command line.
        case letters
    }

    private enum Key {
        static let fontName = "PanelFontName"
        static let fontSize = "PanelFontSize"
        static let quickSearch = "QuickSearchMode"
        static let commandLine = "ShowCommandLine"
        static let functionKeys = "ShowFunctionKeys"
        static let driveButtons = "ShowDriveButtons"
        static let confirmTrash = "ConfirmMoveToTrash"
        static let extraColumns = "ExtraColumns"
        static let checkUpdates = "CheckForUpdates"
    }

    static let defaultFontSize: CGFloat = 12

    static var panelFont: NSFont {
        get {
            let size = CGFloat(AppDefaults.store.double(forKey: Key.fontSize)).nonZero ?? defaultFontSize
            if let name = AppDefaults.store.string(forKey: Key.fontName), let font = NSFont(name: name, size: size) {
                return font
            }
            return .systemFont(ofSize: size)
        }
        set {
            let isSystem = newValue.familyName == NSFont.systemFont(ofSize: 12).familyName
            AppDefaults.store.set(isSystem ? nil : newValue.fontName, forKey: Key.fontName)
            AppDefaults.store.set(Double(newValue.pointSize), forKey: Key.fontSize)
            notify()
        }
    }

    static func resetPanelFont() {
        AppDefaults.store.removeObject(forKey: Key.fontName)
        AppDefaults.store.removeObject(forKey: Key.fontSize)
        notify()
    }

    static var quickSearchMode: QuickSearchMode {
        get { AppDefaults.store.string(forKey: Key.quickSearch).flatMap(QuickSearchMode.init) ?? .optionLetters }
        set { set(newValue.rawValue, Key.quickSearch) }
    }

    static var showsCommandLine: Bool {
        get { bool(Key.commandLine, default: true) }
        set { set(newValue, Key.commandLine) }
    }

    static var showsFunctionKeys: Bool {
        get { bool(Key.functionKeys, default: true) }
        set { set(newValue, Key.functionKeys) }
    }

    static var showsDriveButtons: Bool {
        get { bool(Key.driveButtons, default: true) }
        set { set(newValue, Key.driveButtons) }
    }

    /// Optional metadata columns shown in Full view, in this order.
    static var extraColumns: [SortColumn] {
        get { (AppDefaults.store.stringArray(forKey: Key.extraColumns) ?? []).compactMap(SortColumn.init(rawValue:)) }
        set { set(newValue.map(\.rawValue), Key.extraColumns) }
    }

    static var confirmsMoveToTrash: Bool {
        get { bool(Key.confirmTrash, default: true) }
        set { set(newValue, Key.confirmTrash) }
    }

    /// Looks for a new release on GitHub once a day.
    static var checksForUpdates: Bool {
        get { bool(Key.checkUpdates, default: true) }
        set { set(newValue, Key.checkUpdates) }
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        AppDefaults.store.object(forKey: key) == nil ? value : AppDefaults.store.bool(forKey: key)
    }

    private static func set(_ value: Any, _ key: String) {
        AppDefaults.store.set(value, forKey: key)
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

private extension CGFloat {
    var nonZero: CGFloat? { self == 0 ? nil : self }
}
