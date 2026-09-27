#if DEBUG
import AppKit

/// Development aids driven by environment variables (Debug builds only):
///
/// - `ORICMD_LEFT`, `ORICMD_RIGHT`: initial panel directories.
/// - `ORICMD_KEYS`: space separated keystrokes played after launch, e.g.
///   `down shift+down f7 text:New enter wait`. Only played when both panel
///   directories are given, so a test run never touches real files.
/// - `ORICMD_SNAPSHOT`: PNG path; the window (and an open sheet, as
///   `<name>-sheet.png`) is rendered there after the keys are played.
/// - `ORICMD_QUIT`: exit when done (even with a sheet open).
enum DebugAutomation {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func initialDirectory(left: Bool) -> URL? {
        environment[left ? "ORICMD_LEFT" : "ORICMD_RIGHT"].map { URL(filePath: $0) }
    }

    static func run(in window: NSWindow) {
        var keys = environment["ORICMD_KEYS"]?.split(separator: " ").map(String.init) ?? []
        if !keys.isEmpty && (initialDirectory(left: true) == nil || initialDirectory(left: false) == nil) {
            NSLog("ORICMD_KEYS ignored: set ORICMD_LEFT and ORICMD_RIGHT to test directories")
            keys = []
        }
        let snapshot = environment["ORICMD_SNAPSHOT"]
        guard !keys.isEmpty || snapshot != nil else { return }

        Task {
            try? await Task.sleep(for: .milliseconds(800))
            for token in keys {
                if token == "wait" {
                    try? await Task.sleep(for: .milliseconds(700))
                } else if token.hasPrefix("text:") {
                    type(String(token.dropFirst(5)), in: window)
                } else if let stroke = KeyStroke(token) {
                    play(stroke, in: window)
                } else {
                    NSLog("Unknown key token: \(token)")
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            try? await Task.sleep(for: .milliseconds(400))
            if let snapshot {
                save(window, to: snapshot)
                if let sheet = window.attachedSheet {
                    save(sheet, to: snapshot.replacingOccurrences(of: ".png", with: "-sheet.png"))
                }
            }
            if environment["ORICMD_QUIT"] != nil {
                exit(0)
            }
        }
    }

    /// Inserts text into the focused text field, or types it into the focused view.
    private static func type(_ text: String, in window: NSWindow) {
        let target = window.attachedSheet ?? window
        if let editor = target.firstResponder as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            for character in text {
                play(KeyStroke(characters: String(character), keyCode: 0), in: window)
            }
        }
    }

    /// Delivers a keystroke the way AppKit does: window key equivalents
    /// (default buttons), then menu key equivalents, then `keyDown`.
    private static func play(_ stroke: KeyStroke, in window: NSWindow) {
        let target = window.attachedSheet ?? window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: stroke.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, characters: stroke.characters,
                charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
                isARepeat: false, keyCode: stroke.keyCode
            ) else { continue }
            if type == .keyDown {
                if target.performKeyEquivalent(with: event) { break }
                if target.attachedSheet == nil, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { break }
            }
            target.sendEvent(event)
        }
    }

    private static func save(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }
}

/// A keystroke described as text: "down", "shift+f6", "cmd+a", "x".
private struct KeyStroke {
    var characters: String
    var charactersIgnoringModifiers: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags = []

    init(characters: String, keyCode: UInt16) {
        self.characters = characters
        self.charactersIgnoringModifiers = characters
        self.keyCode = keyCode
    }

    private static let special: [String: (Int, UInt16)] = [
        "up": (NSUpArrowFunctionKey, 126), "down": (NSDownArrowFunctionKey, 125),
        "left": (NSLeftArrowFunctionKey, 123), "right": (NSRightArrowFunctionKey, 124),
        "pageup": (NSPageUpFunctionKey, 116), "pagedown": (NSPageDownFunctionKey, 121),
        "home": (NSHomeFunctionKey, 115), "end": (NSEndFunctionKey, 119),
        "insert": (NSInsertFunctionKey, 114), "forwarddelete": (NSDeleteFunctionKey, 117),
        "enter": (0x0D, 36), "tab": (0x09, 48), "backspace": (0x7F, 51),
        "space": (0x20, 49), "escape": (0x1B, 53),
        "f1": (NSF1FunctionKey, 122), "f2": (NSF2FunctionKey, 120), "f3": (NSF3FunctionKey, 99),
        "f4": (NSF4FunctionKey, 118), "f5": (NSF5FunctionKey, 96), "f6": (NSF6FunctionKey, 97),
        "f7": (NSF7FunctionKey, 98), "f8": (NSF8FunctionKey, 100), "f9": (NSF9FunctionKey, 101),
        "f10": (NSF10FunctionKey, 109), "f11": (NSF11FunctionKey, 103), "f12": (NSF12FunctionKey, 111),
        "plus": (0x2B, 24), "minus": (0x2D, 27), "star": (0x2A, 28),
    ]

    init?(_ token: String) {
        var parts = token.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        if let (code, keyCode) = Self.special[key] {
            self.init(characters: String(UnicodeScalar(UInt32(code))!), keyCode: keyCode)
            if code >= 0xF700 {
                modifiers.insert(.function)
            }
        } else if key.count == 1 {
            self.init(characters: key, keyCode: 0)
        } else {
            return nil
        }
        self.modifiers = modifiers
    }
}
#endif
