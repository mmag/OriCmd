import AppKit
import Carbon.HIToolbox

/// Shortcuts are tied to physical keys, as in Total Commander: ⌃D is the same
/// key on the Russian layout (where it types "в") as on the US one, and so is ⌃`
/// (typed as "]" or "ё" there).
nonisolated enum KeyboardLayout {
    #if DEBUG
    /// Test runs play keys typed on a non-Latin layout without switching the user's.
    nonisolated(unsafe) static var simulatesNonLatinLayout = false
    #endif

    /// Whether the active layout types non-Latin letters (Russian, …): its keys
    /// are then matched by position, as typed on the Latin layout.
    static var isNonLatinLayoutActive: Bool {
        #if DEBUG
        if simulatesNonLatinLayout { return true }
        #endif
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return !CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    /// The character `keyCode` types on the ASCII-capable layout (US or ABC
    /// on a Mac with a Russian layout), or nil for keys without one.
    static func latinCharacter(keyCode: UInt16, shift: Bool = false) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let text = character(keyCode: keyCode, shift: shift, on: source) else { return nil }
        // Printable only ("§" too: the key under Esc of ISO keyboards).
        return text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }) ? text : nil
    }

    #if DEBUG
    /// The character `keyCode` types on the installed layout `id` ("com.apple.keylayout.RussianWin").
    static func character(keyCode: UInt16, onLayout id: String) -> String? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return character(keyCode: keyCode, shift: false, on: source)
    }
    #endif

    private static func character(keyCode: UInt16, shift: Bool, on source: TISInputSource) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifierState = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = layoutData.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

nonisolated extension NSEvent {
    /// `charactersIgnoringModifiers` for matching shortcuts: lowercased, and taken
    /// from the Latin layout when the active one types something else there.
    var shortcutCharacters: String? {
        guard let characters = charactersIgnoringModifiers else { return nil }
        guard type == .keyDown || type == .keyUp, specialKey == nil,
              characters.unicodeScalars.contains(where: { !$0.isASCII }) || KeyboardLayout.isNonLatinLayoutActive,
              let latin = KeyboardLayout.latinCharacter(keyCode: keyCode, shift: modifierFlags.contains(.shift))
        else { return characters.lowercased() }
        return latin.lowercased()
    }

    /// The same key press as typed on the Latin layout, for a ⌘, ⌃ or ⌥ shortcut
    /// pressed while a non-Latin layout is active; nil when nothing changes.
    var latinized: NSEvent? {
        let modifiers = modifierFlags.intersection([.command, .control, .option])
        guard !modifiers.isEmpty, type == .keyDown, specialKey == nil,
              let original = charactersIgnoringModifiers,
              original.unicodeScalars.contains(where: { !$0.isASCII }) || KeyboardLayout.isNonLatinLayoutActive,
              let latin = KeyboardLayout.latinCharacter(keyCode: keyCode, shift: modifierFlags.contains(.shift)),
              latin != original else { return nil }
        let characters = modifiers == .option ? latin : (self.characters.flatMap { text in
            text.unicodeScalars.allSatisfy { $0.value < 0x20 } ? text : nil
        } ?? latin)
        return NSEvent.keyEvent(
            with: type, location: locationInWindow, modifierFlags: modifierFlags,
            timestamp: timestamp, windowNumber: windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: latin,
            isARepeat: isARepeat, keyCode: keyCode
        )
    }
}

/// The main menu: shortcuts also match when typed on a non-Latin layout.
nonisolated final class ShortcutMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard let latin = event.latinized else { return false }
        return super.performKeyEquivalent(with: latin)
    }
}
