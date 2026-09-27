import AppKit

/// A menu key equivalent: key character plus modifiers.
nonisolated struct Shortcut: Equatable, Sendable {
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

// MARK: - Text form

extension Shortcut {
    /// Key names used in the text form (and in Total Commander's wincmd.ini).
    private static let namedKeys: [String: Int] = [
        "UP": NSUpArrowFunctionKey, "DOWN": NSDownArrowFunctionKey, "LEFT": NSLeftArrowFunctionKey,
        "RIGHT": NSRightArrowFunctionKey, "PGUP": NSPageUpFunctionKey, "PGDN": NSPageDownFunctionKey,
        "HOME": NSHomeFunctionKey, "END": NSEndFunctionKey, "INS": NSInsertFunctionKey,
        "DEL": NSDeleteFunctionKey, "BACK": 0x08, "TAB": 0x09, "ENTER": 0x0D, "SPACE": 0x20, "ESC": 0x1B,
    ]

    /// Parses "CS+F5", "M+K", "A+Down", "F7" — C Control, A Option (Alt),
    /// S Shift, M Command. Total Commander's "W" (Windows key) is read as Command.
    init?(text: String) {
        var modifierPart = ""
        var keyPart = text.trimmingCharacters(in: .whitespaces)
        if let plus = keyPart.firstIndex(of: "+"), plus != keyPart.startIndex, keyPart.index(after: plus) != keyPart.endIndex {
            modifierPart = String(keyPart[..<plus]).uppercased()
            keyPart = String(keyPart[keyPart.index(after: plus)...])
        }
        var modifiers: NSEvent.ModifierFlags = []
        for letter in modifierPart {
            switch letter {
            case "C": modifiers.insert(.control)
            case "A": modifiers.insert(.option)
            case "S": modifiers.insert(.shift)
            case "M", "W": modifiers.insert(.command)
            default: return nil
            }
        }
        let upper = keyPart.uppercased()
        if upper.hasPrefix("F"), let number = Int(upper.dropFirst()), (1...12).contains(number) {
            self = .f(number, modifiers)
        } else if let code = Self.namedKeys[upper] {
            self.init(String(UnicodeScalar(UInt32(code))!), modifiers)
        } else if keyPart.count == 1 {
            self.init(keyPart.lowercased(), modifiers)
        } else {
            return nil
        }
    }

    var text: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C" }
        if modifiers.contains(.option) { prefix += "A" }
        if modifiers.contains(.shift) { prefix += "S" }
        if modifiers.contains(.command) { prefix += "M" }
        let name: String
        if let scalar = key.unicodeScalars.first, (0xF704...0xF70F).contains(scalar.value) {
            name = "F\(scalar.value - 0xF704 + 1)"
        } else if let scalar = key.unicodeScalars.first,
                  let named = Self.namedKeys.first(where: { $0.value == Int(scalar.value) })?.key {
            name = named.capitalized
        } else {
            name = key.uppercased()
        }
        return prefix.isEmpty ? name : prefix + "+" + name
    }

    /// The shortcut a key press stands for (while recording one).
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let special = event.specialKey {
            let value = special.rawValue
            if (0xF704...0xF70F).contains(value) {
                self = .f(value - 0xF704 + 1, modifiers)
                return
            }
            let code = value == NSEvent.SpecialKey.delete.rawValue ? 0x08 : value
            self.init(String(UnicodeScalar(UInt32(code))!), modifiers)
            return
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
        self.init(characters, modifiers)
    }
}
