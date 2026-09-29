import AppKit

/// Panel colors chosen in Settings: marked files, cursor, alternating rows and
/// file colors by mask (Total Commander's "Define colors by file type").
/// Values are cached; changing them posts `Settings.didChange`.
enum ColorSettings {
    struct Rule: Codable, Equatable {
        var mask: String
        var color: String
    }

    private enum Key {
        static let marked = "MarkedColor"
        static let cursor = "CursorColor"
        static let cursorText = "CursorTextColor"
        static let alternating = "AlternatingRows"
        static let rules = "FileColorRules"
        static let boldMarked = "BoldMarkedFiles"
    }

    private static var cache: (marked: NSColor?, cursor: NSColor?, cursorText: NSColor?,
                               alternating: Bool, boldMarked: Bool, rules: [(mask: String, color: NSColor)])?

    private static var values: (marked: NSColor?, cursor: NSColor?, cursorText: NSColor?,
                                alternating: Bool, boldMarked: Bool, rules: [(mask: String, color: NSColor)]) {
        if let cache { return cache }
        let store = AppDefaults.store
        let loaded = (
            marked: store.string(forKey: Key.marked).flatMap(NSColor.init(hex:)),
            cursor: store.string(forKey: Key.cursor).flatMap(NSColor.init(hex:)),
            cursorText: store.string(forKey: Key.cursorText).flatMap(NSColor.init(hex:)),
            alternating: store.bool(forKey: Key.alternating),
            boldMarked: store.bool(forKey: Key.boldMarked),
            rules: rules.compactMap { rule in NSColor(hex: rule.color).map { (rule.mask, readable($0)) } }
        )
        cache = loaded
        return loaded
    }

    /// The color of marked files as chosen (lighter on a dark background, as file colors).
    static var markedColor: NSColor? {
        get { values.marked.map(readable) }
        set { store(newValue?.hexString, Key.marked) }
    }

    /// The color of marked files as stored (for the color well).
    static var chosenMarkedColor: NSColor? { values.marked }

    /// Marked files are drawn in bold too: then marking does not rely on color alone.
    static var boldMarked: Bool {
        get { values.boldMarked }
        set { store(newValue, Key.boldMarked) }
    }

    static var cursorColor: NSColor? {
        get { values.cursor }
        set { store(newValue?.hexString, Key.cursor) }
    }

    static var cursorTextColor: NSColor? {
        get { values.cursorText }
        set { store(newValue?.hexString, Key.cursorText) }
    }

    static var alternatingRows: Bool {
        get { values.alternating }
        set { store(newValue, Key.alternating) }
    }

    static var rules: [Rule] {
        get {
            guard let data = AppDefaults.store.data(forKey: Key.rules) else { return [] }
            return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
        }
        set { store(try? JSONEncoder().encode(newValue), Key.rules) }
    }

    /// A file color as chosen, and lighter on a dark background, where the
    /// usual dark purples and blues would hardly be readable.
    private static func readable(_ color: NSColor) -> NSColor {
        let lighter = color.blended(withFraction: 0.4, of: .white) ?? color
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? lighter : color
        }
    }

    /// The color of the first rule whose mask matches `name`.
    static func color(forName name: String) -> NSColor? {
        values.rules.first { FileMask.matches(name, $0.mask) }?.color
    }

    static func resetPanelColors() {
        for key in [Key.marked, Key.cursor, Key.cursorText] {
            AppDefaults.store.removeObject(forKey: key)
        }
        changed()
    }

    /// Ready-made colors, also for people who tell some colors apart with difficulty.
    /// A preset sets the marked files' color (and bold) and the file colors.
    enum Preset: CaseIterable {
        case standard, redGreen, blueYellow, highContrast

        var title: String {
            switch self {
            case .standard: String(localized: "Standard")
            case .redGreen: String(localized: "Red–green color blindness (protanopia, deuteranopia)")
            case .blueYellow: String(localized: "Blue–yellow color blindness (tritanopia)")
            case .highContrast: String(localized: "High contrast")
            }
        }

        /// Marked files' color (nil: the standard red), whether they are bold, file colors.
        private var colors: (marked: String?, bold: Bool, rules: [String]) {
            switch self {
            case .standard:
                (nil, false, ColorSettings.exampleRules.map(\.color))
            // Okabe–Ito colors, darkened for text on white: blue for marked files, then
            // vermillion, reddish purple, bluish green and orange.
            case .redGreen:
                ("#0060A0", true, ["#B34700", "#A0527F", "#007A5A", "#9A6A00"])
            // Red stays apart from green and blue; blue with green, and yellow with
            // violet, are what is avoided.
            case .blueYellow:
                ("#C00000", true, ["#B0307A", "#007A7A", "#8C5A00", "#5A5A5A"])
            case .highContrast:
                ("#D00000", true, ["#6A1B9A", "#0B6E4F", "#0D47A1", "#8D4E00"])
            }
        }

        func apply() {
            let colors = colors
            AppDefaults.store.set(colors.marked, forKey: Key.marked)
            AppDefaults.store.set(colors.bold, forKey: Key.boldMarked)
            // High contrast stripes the rows; back to standard, they are plain again.
            if self == .highContrast || self == .standard {
                AppDefaults.store.set(self == .highContrast, forKey: Key.alternating)
            }
            let masks = ColorSettings.exampleRules.map(\.mask)
            ColorSettings.rules = zip(masks, colors.rules).map { Rule(mask: $0, color: $1) }
        }
    }

    /// Whether the colors were changed from the standard ones (a preset would replace them).
    static var areCustomized: Bool {
        values.marked != nil || values.boldMarked || rules != exampleRules
    }

    /// Examples in the spirit of Total Commander setups.
    static let exampleRules: [Rule] = [
        Rule(mask: "*.zip;*.rar;*.7z;*.tar;*.gz;*.tgz;*.bz2;*.xz;*.dmg", color: "#C0392B"),
        Rule(mask: "*.jpg;*.jpeg;*.png;*.gif;*.heic;*.tif;*.tiff;*.webp", color: "#8E44AD"),
        Rule(mask: "*.mp3;*.m4a;*.flac;*.wav;*.mp4;*.mov;*.mkv;*.avi", color: "#2980B9"),
        Rule(mask: "*.sh;*.command;*.py;*.rb;*.pl", color: "#27AE60"),
    ]

    private static func store(_ value: Any?, _ key: String) {
        AppDefaults.store.set(value, forKey: key)
        changed()
    }

    private static func changed() {
        cache = nil
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)),
                      Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
    }
}
