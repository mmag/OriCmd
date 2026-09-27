import AppKit

/// A menu key equivalent: key character plus modifiers.
struct Shortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Function key F1…F12.
    static func f(_ number: Int, _ modifiers: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(String(UnicodeScalar(UInt32(NSF1FunctionKey + number - 1))!), modifiers)
    }

    static func cmd(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(key, extra.union(.command))
    }

    static func ctrl(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(key, extra.union(.control))
    }
}
