import AppKit

/// The user's own keys for commands: overrides of the main key (an empty
/// override removes it) and extra keys, e.g. imported from Total Commander.
enum KeyBindings {
    static let didChange = Notification.Name("OriCmdKeyBindingsDidChange")
    private static let key = "KeyBindings"
    private static let extraKey = "ExtraKeyBindings"

    private static var overrides: [String: String] {
        AppDefaults.store.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static var extraTexts: [String: [String]] {
        AppDefaults.store.dictionary(forKey: extraKey) as? [String: [String]] ?? [:]
    }

    /// Additional keys for `command` (besides its main key and built-in aliases).
    static func extras(for command: Command) -> [Shortcut] {
        (extraTexts[command.rawValue] ?? []).compactMap(Shortcut.init(text:))
    }

    /// Adds an extra key; other commands lose it. Returns them.
    @discardableResult
    static func addExtra(_ shortcut: Shortcut, for command: Command) -> [Command] {
        let takenFrom = release(shortcut, keeping: command)
        var extras = extraTexts
        var list = extras[command.rawValue] ?? []
        if !list.contains(shortcut.text) && self.shortcut(for: command) != shortcut {
            list.append(shortcut.text)
        }
        extras[command.rawValue] = list
        AppDefaults.store.set(extras, forKey: extraKey)
        notify()
        return takenFrom
    }

    /// Removes `shortcut` from every other command (main key and extras).
    private static func release(_ shortcut: Shortcut, keeping command: Command) -> [Command] {
        var list = overrides
        var extras = extraTexts
        var takenFrom: [Command] = []
        for other in Command.allCases where other != command {
            if self.shortcut(for: other) == shortcut {
                list[other.rawValue] = ""
                takenFrom.append(other)
            }
            if let keys = extras[other.rawValue], keys.contains(shortcut.text) {
                extras[other.rawValue] = keys.filter { $0 != shortcut.text }
                takenFrom.append(other)
            }
        }
        AppDefaults.store.set(list, forKey: key)
        AppDefaults.store.set(extras, forKey: extraKey)
        return takenFrom
    }

    static func shortcut(for command: Command) -> Shortcut? {
        guard let text = overrides[command.rawValue] else { return command.defaultShortcut }
        return text.isEmpty ? nil : Shortcut(text: text)
    }

    static func isCustomized(_ command: Command) -> Bool {
        overrides[command.rawValue] != nil || !(extraTexts[command.rawValue] ?? []).isEmpty
    }

    /// Assigns the main key (nil: no key); other commands lose the same key.
    /// Returns the commands it was taken from.
    @discardableResult
    static func set(_ shortcut: Shortcut?, for command: Command) -> [Command] {
        let takenFrom = shortcut.map { release($0, keeping: command) } ?? []
        var list = overrides
        list[command.rawValue] = shortcut?.text ?? ""
        AppDefaults.store.set(list, forKey: key)
        notify()
        return takenFrom
    }

    /// Back to the default key, without extra keys.
    static func reset(_ command: Command) {
        var list = overrides
        list[command.rawValue] = nil
        var extras = extraTexts
        extras[command.rawValue] = nil
        AppDefaults.store.set(list, forKey: key)
        AppDefaults.store.set(extras, forKey: extraKey)
        notify()
    }

    static func resetAll() {
        AppDefaults.store.removeObject(forKey: key)
        AppDefaults.store.removeObject(forKey: extraKey)
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Reads the [Shortcuts] section of Total Commander's wincmd.ini
    /// ("CS+F5=cm_CreateShortcut") and adds those keys, as Total Commander adds
    /// them to its built-in ones. Returns how many keys were taken over and the
    /// lines that could not be (unknown commands or keys).
    static func importTotalCommanderShortcuts(from url: URL) throws -> (imported: Int, skipped: [String]) {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? ""
        var inSection = false
        var imported = 0
        var skipped: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.caseInsensitiveCompare("[Shortcuts]") == .orderedSame
                continue
            }
            guard inSection, let equals = line.firstIndex(of: "=") else { continue }
            let keys = String(line[..<equals])
            let name = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard let command = Command(rawValue: name), command != .exit, let shortcut = Shortcut(text: keys) else {
                skipped.append(line)
                continue
            }
            addExtra(shortcut, for: command)
            imported += 1
        }
        return (imported, skipped)
    }
}
