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
        static let appearance = "Appearance"
        static let languages = "AppleLanguages"
        static let copyOverwrite = "CopyOverwriteMode"
        static let copyVerify = "CopyVerify"
        static let copyAttributes = "CopyAttributes"
        static let copySkipUnreadable = "CopySkipUnreadable"
        static let copyOverwriteLocked = "CopyOverwriteLocked"
        static let rightButton = "RightMouseButton"
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

    /// What the right mouse button does on a panel's files.
    enum RightButton: String {
        /// Shows the context menu, as in the Finder.
        case menu
        /// Marks and unmarks files (a drag over several marks them all); held still,
        /// shows the context menu.
        case marks
    }

    static var rightButton: RightButton {
        get { AppDefaults.store.string(forKey: Key.rightButton).flatMap(RightButton.init) ?? .menu }
        set { set(newValue.rawValue, Key.rightButton) }
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

    /// Light or dark look: the system's, or chosen for OriCmd only.
    enum Appearance: String, CaseIterable {
        case system, light, dark
    }

    static var appearance: Appearance {
        get { AppDefaults.store.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system }
        set {
            set(newValue.rawValue, Key.appearance)
            applyAppearance()
        }
    }

    /// Takes effect at once in every window.
    static func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The interface language: the system's, or one chosen for OriCmd only.
    enum Language: String, CaseIterable {
        case system = "", english = "en", russian = "ru"
    }

    /// Takes effect after a restart (macOS reads AppleLanguages at launch).
    static var language: Language {
        get {
            let domain = AppDefaults.store.persistentDomain(forName: AppDefaults.domainName)
            guard let first = (domain?[Key.languages] as? [String])?.first else { return .system }
            return Language.allCases.first { !$0.rawValue.isEmpty && first.hasPrefix($0.rawValue) } ?? .system
        }
        set {
            if newValue == .system {
                AppDefaults.store.removeObject(forKey: Key.languages)
            } else {
                AppDefaults.store.set([newValue.rawValue], forKey: Key.languages)
            }
        }
    }

    /// The language the interface is shown in right now.
    static var runningLanguage: Language {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return code.hasPrefix("ru") ? .russian : .english
    }

    // Defaults of the F5 / F6 dialog (its save button writes them as well).

    static var copyOverwriteMode: OverwriteMode {
        get { OverwriteMode(rawValue: AppDefaults.store.integer(forKey: Key.copyOverwrite)) ?? .ask }
        set { set(newValue.rawValue, Key.copyOverwrite) }
    }

    static var copyVerifies: Bool {
        get { bool(Key.copyVerify, default: false) }
        set { set(newValue, Key.copyVerify) }
    }

    static var copyAttributes: Bool {
        get { bool(Key.copyAttributes, default: true) }
        set { set(newValue, Key.copyAttributes) }
    }

    static var copySkipsUnreadable: Bool {
        get { bool(Key.copySkipUnreadable, default: false) }
        set { set(newValue, Key.copySkipUnreadable) }
    }

    static var copyOverwritesLocked: Bool {
        get { bool(Key.copyOverwriteLocked, default: false) }
        set { set(newValue, Key.copyOverwriteLocked) }
    }

    /// Looks for a new release on GitHub once a day.
    static var checksForUpdates: Bool {
        get { bool(Key.checkUpdates, default: true) }
        set { set(newValue, Key.checkUpdates) }
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        AppDefaults.store.object(forKey: key) == nil ? value : AppDefaults.store.bool(forKey: key)
    }

    /// Tells the windows to show settings changed elsewhere (column sets).
    static func notifyChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
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
