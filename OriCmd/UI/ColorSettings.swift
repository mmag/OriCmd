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
    }

    private static var cache: (marked: NSColor?, cursor: NSColor?, cursorText: NSColor?,
                               alternating: Bool, rules: [(mask: String, color: NSColor)])?

    private static var values: (marked: NSColor?, cursor: NSColor?, cursorText: NSColor?,
                                alternating: Bool, rules: [(mask: String, color: NSColor)]) {
        if let cache { return cache }
        let store = AppDefaults.store
        let loaded = (
            marked: store.string(forKey: Key.marked).flatMap(NSColor.init(hex:)),
            cursor: store.string(forKey: Key.cursor).flatMap(NSColor.init(hex:)),
            cursorText: store.string(forKey: Key.cursorText).flatMap(NSColor.init(hex:)),
            alternating: store.bool(forKey: Key.alternating),
            rules: rules.compactMap { rule in NSColor(hex: rule.color).map { (rule.mask, readable($0)) } }
        )
        cache = loaded
        return loaded
    }

    static var markedColor: NSColor? {
        get { values.marked }
        set { store(newValue?.hexString, Key.marked) }
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
