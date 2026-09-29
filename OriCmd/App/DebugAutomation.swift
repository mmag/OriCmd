#if DEBUG
import AppKit
import ApplicationServices

/// Development aids driven by environment variables (Debug builds only):
///
/// - `ORICMD_LEFT`, `ORICMD_RIGHT`: initial panel directories.
/// - `ORICMD_KEYS`: space separated keystrokes played after launch, e.g.
///   `down shift+down f7 text:New enter wait`, or commands like `cmd:cm_SyncDirs`,
///   `menu` (writes the context menu to `<snapshot>-menu.txt`), `drop:/path`, `drive:/path` (a drive
///   button), `tabbardoubleclick` (the empty end of the tab bar), `promise:/path` (the file on the
///   clipboard as a promise, plus a placeholder of zeros), `lazyfile:/path` (as Microsoft Remote Desktop
///   does: a placeholder written only when read through file coordination), `click:Button_Title`,
///   `dropapp:/path/App.app` (onto the toolbar), `clickapp:App_Name`, `rightclickapp:App_Name|Menu_Item`.
///   Only played when both panel directories are given, so a test run never touches real files.
/// - `ORICMD_SNAPSHOT`: PNG path; the window (and an open sheet, as
///   `<name>-sheet.png`) is rendered there after the keys are played; a server
///   terminal of the active panel as `<name>-terminal.png` and `.txt`.
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
                } else if token == "menu", let list = window.firstResponder as? FileListView,
                          let menu = list.delegate?.fileList(list, contextMenuFor: list.selectedEntries),
                          let snapshot = environment["ORICMD_SNAPSHOT"] {
                    // Writes the context menu's titles next to the snapshot.
                    let titles = menu.items.map { item in
                        item.isSeparatorItem ? "---" : item.title
                            + (item.submenu.map { " ▸ " + $0.items.map(\.title).joined(separator: " | ") } ?? "")
                    }
                    try? titles.joined(separator: "\n").write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                                                atomically: true, encoding: .utf8)
                } else if token.hasPrefix("drop:"), let list = window.firstResponder as? FileListView {
                    // Simulates dropping a file onto the focused panel.
                    _ = list.delegate?.fileList(list, drop: [URL(filePath: String(token.dropFirst(5)))], into: nil, moving: false)
                } else if token.hasPrefix("drive:"), let main = window.contentViewController as? MainViewController {
                    // Simulates a click on a drive button of the active panel.
                    main.activePanel.panelView.driveBar.onSelect?(URL(filePath: String(token.dropFirst(6))))
                } else if token == "tabbardoubleclick", let main = window.contentViewController as? MainViewController {
                    // A double click on the empty end of the active panel's tab bar.
                    let bar = main.activePanel.panelView.tabBar
                    let point = bar.convert(NSPoint(x: bar.bounds.maxX - 4, y: bar.bounds.midY), to: nil)
                    if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 2, pressure: 1) {
                        bar.mouseDown(with: event)
                    }
                } else if token.hasPrefix("lazyfile:") {
                    offerLazyFile(URL(filePath: String(token.dropFirst(9))))
                } else if token.hasPrefix("promise:") {
                    offerPromise(of: URL(filePath: String(token.dropFirst(8))))
                } else if token.hasPrefix("dropapp:") {
                    // Simulates dropping an application onto the toolbar.
                    (window.windowController as? MainWindowController)?
                        .addApplications([URL(filePath: String(token.dropFirst(8)))])
                } else if token.hasPrefix("clickapp:") {
                    // Clicks the toolbar button of that application.
                    let name = String(token.dropFirst(9)).replacingOccurrences(of: "_", with: " ")
                    (window.toolbar?.items.compactMap { $0.view as? AppButton }
                        .first { ToolbarApps.name(of: $0.path) == name })?.performClick(nil)
                } else if token.hasPrefix("rightclickapp:") {
                    // Right-clicks the toolbar button of an application; the menu shown is
                    // written to <snapshot>-menu.txt and its item named after "|" is chosen.
                    // No menu shown (no such button, or a sheet is open) leaves the file empty.
                    let parts = String(token.dropFirst(14)).replacingOccurrences(of: "_", with: " ")
                        .split(separator: "|", maxSplits: 1).map(String.init)
                    if let snapshot {
                        try? "".write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                      atomically: true, encoding: .utf8)
                    }
                    guard let mainWindow = window as? MainWindow,
                          let button = window.toolbar?.items.compactMap({ $0.view as? AppButton })
                            .first(where: { ToolbarApps.name(of: $0.path) == parts[0] }),
                          let event = NSEvent.mouseEvent(
                            with: .rightMouseDown, location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    else { continue }
                    let choice = parts.count > 1 ? parts[1] : nil
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                          object: nil, queue: nil) { note in
                        nonisolated(unsafe) let tracked = note.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            if let snapshot {
                                try? menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
                                    .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                           atomically: true, encoding: .utf8)
                            }
                            let item = menu.items.first { $0.title == choice }
                            RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                                menu.cancelTracking()
                                if let item, let index = menu.items.firstIndex(of: item) {
                                    menu.performActionForItem(at: index)
                                }
                            }
                        }
                    }
                    _ = mainWindow.showAppButtonMenu(for: event)
                    NotificationCenter.default.removeObserver(observer)
                } else if token.hasPrefix("importini:") {
                    _ = try? KeyBindings.importTotalCommanderShortcuts(from: URL(filePath: String(token.dropFirst(10))))
                } else if token.hasPrefix("click:") {
                    // Presses the button with that title in the topmost window.
                    let title = String(token.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
                    @MainActor func find(_ view: NSView?) -> NSButton? {
                        guard let view else { return nil }
                        if let button = view as? NSButton, button.title == title { return button }
                        return view.subviews.lazy.compactMap(find).first
                    }
                    find(topmost(window).contentView)?.performClick(nil)
                } else if token.hasPrefix("cmd:") {
                    perform(Selector(String(token.dropFirst(4)) + ":"), in: window)
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
                // The active panel's terminal, as text and as a picture of its own
                // (its layer's drawing does not show in the window's picture).
                if let main = window.contentViewController as? MainViewController,
                   let terminal = main.activePanel.panelView.terminalPane.terminal {
                    try? main.activePanel.panelView.terminalPane.screenText?
                        .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-terminal.txt"),
                               atomically: true, encoding: .utf8)
                    save(terminal, to: snapshot.replacingOccurrences(of: ".png", with: "-terminal.png"))
                }
                var sheet = window.attachedSheet
                var suffix = "-sheet"
                while let current = sheet {
                    save(current, to: snapshot.replacingOccurrences(of: ".png", with: "\(suffix).png"))
                    sheet = current.attachedSheet
                    suffix += "2"
                }
                let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.sheetParent == nil }
                for (index, other) in others.enumerated() {
                    save(other, to: snapshot.replacingOccurrences(of: ".png", with: "-win\(index + 1).png"))
                }
            }
            if environment["ORICMD_QUIT"] != nil {
                exit(0)
            }
        }
    }

    /// Inserts text into the focused text field, or types it into the focused view.
    /// The window that receives keys: the frontmost window (e.g. a Lister)
    /// or its topmost sheet.
    private static func topmost(_ window: NSWindow) -> NSWindow {
        var target = NSApp.orderedWindows.first { $0.isVisible && $0.sheetParent == nil } ?? window
        while let sheet = target.attachedSheet {
            target = sheet
        }
        return target
    }

    private static func type(_ text: String, in window: NSWindow) {
        let target = topmost(window)
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
        KeyboardLayout.simulatesNonLatinLayout = stroke.isRussian
        defer { KeyboardLayout.simulatesNonLatinLayout = false }
        let target = topmost(window)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: stroke.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, characters: stroke.characters,
                charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
                isARepeat: false, keyCode: stroke.keyCode
            ) else { continue }
            if type == .keyDown {
                // Esc as the app-wide monitor sees it before anything else.
                if EscapeKey.handle(event, in: target) { break }
                if target.sheetParent != nil, stroke.characters == "\r", let cell = target.defaultButtonCell {
                    cell.performClick(nil)
                    break
                }
                if target.sheetParent != nil, let button = button(for: stroke, in: target.contentView) {
                    button.performClick(nil)
                    break
                }
                // Return reaches the focused view first unless a text field is being
                // edited, in which case the default button takes it (as in AppKit).
                let isReturn = stroke.characters == "\r"
                if !isReturn || target.firstResponder is NSTextView,
                   target.performKeyEquivalent(with: event) { break }
                if target.attachedSheet == nil, target.sheetParent == nil,
                   performMenuShortcut(event, in: target) || event.latinized.map({ performMenuShortcut($0, in: target) }) == true {
                    break
                }
            }
            target.sendEvent(event)
        }
    }

    /// The sheet button whose key equivalent matches `stroke` (Return, Escape…).
    private static func button(for stroke: KeyStroke, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.isEnabled,
           button.keyEquivalent == stroke.characters,
           button.keyEquivalentModifierMask == stroke.modifiers.subtracting(.function) {
            return button
        }
        for subview in view.subviews {
            if let found = button(for: stroke, in: subview) { return found }
        }
        return nil
    }

    /// Sends a command (e.g. `cm_SyncDirs:`) along the window's responder chain.
    @discardableResult
    private static func perform(_ action: Selector, in window: NSWindow) -> Bool {
        var responder = topmost(window).firstResponder
        while let current = responder {
            if current.responds(to: action) {
                return NSApp.sendAction(action, to: current, from: nil)
            }
            if let supplemental = current.supplementalTarget(forAction: action, sender: nil) {
                return NSApp.sendAction(action, to: supplemental, from: nil)
            }
            responder = current.nextResponder
        }
        if let delegate = NSApp.delegate, delegate.responds(to: action) {
            return NSApp.sendAction(action, to: delegate, from: nil)
        }
        NSLog("No target for \(action)")
        return false
    }

    /// Finds the menu item for `stroke` and sends its action along the window's
    /// responder chain. Unlike `NSMenu.performKeyEquivalent`, this also works
    /// while the app is inactive (e.g. the screen is locked during a test run).
    private static func performMenuShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.subtracting(.function)
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
                if item.keyEquivalent == event.charactersIgnoringModifiers,
                   item.keyEquivalentModifierMask == modifiers,
                   !item.isHidden || item.allowsKeyEquivalentWhenHidden {
                    return item
                }
            }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap(find(in:)), let action = item.action else { return false }

        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) {
                return NSApp.sendAction(action, to: current, from: item)
            }
            if let supplemental = current.supplementalTarget(forAction: action, sender: item) {
                return NSApp.sendAction(action, to: supplemental, from: item)
            }
            responder = current.nextResponder
        }
        if let delegate = NSApp.delegate, delegate.responds(to: action) {
            return NSApp.sendAction(action, to: delegate, from: item)
        }
        return false
    }

    private static var lazyFilePresenter: LazyFilePresenter?

    /// Puts on the (test) clipboard a placeholder of `file`, zero-filled and sparse, that
    /// is written only when someone reads it through file coordination.
    private static func offerLazyFile(_ file: URL) {
        let placeholders = file.deletingLastPathComponent().deletingLastPathComponent().appending(path: "placeholder")
        try? FileManager.default.createDirectory(at: placeholders, withIntermediateDirectories: true)
        let placeholder = placeholders.appending(path: file.lastPathComponent)
        FileManager.default.createFile(atPath: placeholder.path, contents: nil)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let handle = try? FileHandle(forWritingTo: placeholder) {
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        let presenter = LazyFilePresenter(placeholder: placeholder, source: file)
        NSFileCoordinator.addFilePresenter(presenter)
        lazyFilePresenter = presenter
        AppDefaults.pasteboard.clearContents()
        AppDefaults.pasteboard.writeObjects([placeholder as NSURL])
    }

    /// The file promised by `offerPromise` (the promise keeper is a C function), and the
    /// pasteboard reference that keeps the promise (released, it could not be kept).
    nonisolated(unsafe) private static var promisedFile: URL?
    private static var promiseBoard: Pasteboard?

    /// Writes the promised file into the receiver's paste location. Called on the
    /// receiver's thread (a local promise), so not isolated to the main actor.
    nonisolated private static let promiseKeeper: PasteboardPromiseKeeperProcPtr = { board, item, flavor, _ in
        var location: CFURL?
        guard PasteboardCopyPasteLocation(board, &location) == noErr,
              let folder = location as URL?, let source = DebugAutomation.promisedFile else {
            return OSStatus(badPasteboardFlavorErr)
        }
        let target = folder.appending(path: source.lastPathComponent)
        try? FileManager.default.copyItem(at: source, to: target)
        return PasteboardPutItemFlavor(board, item, flavor, Data(target.absoluteString.utf8) as CFData, [])
    }

    /// Puts `file` on the (test) clipboard as Microsoft Remote Desktop does: a promise
    /// of the file, and the URL of a placeholder of the same size full of zeros, in a
    /// "placeholder" folder next to the file's folder.
    private static func offerPromise(of file: URL) {
        var created: Pasteboard?
        guard PasteboardCreate(AppDefaults.pasteboard.name.rawValue as CFString, &created) == noErr,
              let board = created else { return }
        PasteboardClear(board)
        PasteboardSynchronize(board)
        promisedFile = file
        promiseBoard = board
        PasteboardSetPromiseKeeper(board, promiseKeeper, nil)
        guard let item = PasteboardItemID(bitPattern: 1) else { return }
        PasteboardPutItemFlavor(board, item, kPasteboardTypeFileURLPromise as CFString, nil, [])
        PasteboardPutItemFlavor(board, item, kPasteboardTypeFilePromiseContent as CFString,
                                Data("public.data".utf8) as CFData, [])
        let placeholders = file.deletingLastPathComponent().deletingLastPathComponent().appending(path: "placeholder")
        try? FileManager.default.createDirectory(at: placeholders, withIntermediateDirectories: true)
        let placeholder = placeholders.appending(path: file.lastPathComponent)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        FileManager.default.createFile(atPath: placeholder.path, contents: Data(count: size))
        PasteboardPutItemFlavor(board, item, "public.file-url" as CFString,
                                Data(placeholder.absoluteString.utf8) as CFData, [])
    }

    private static func save(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview else { return }
        save(view, to: path)
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
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
    /// Typed with the Russian layout active ("ru+").
    var isRussian = false

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

    /// ANSI key codes, so menus match synthetic events like real ones.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "§": 10,
    ]

    /// The Russian (PC) layout on the keys of the US one, if the real one is missing.
    private static let russian: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(
        "qwertyuiop[]asdfghjkl;'zxcvbnm,.`", "йцукенгшщзхъфывапролджэячсмитьбюё"
    ))

    init?(_ token: String) {
        var parts = token.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        var russian = false
        for part in parts {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "num": modifiers.insert(.numericPad)
            case "ru": russian = true
            default: return nil
            }
        }
        if let (code, keyCode) = Self.special[key] {
            self.init(characters: String(UnicodeScalar(UInt32(code))!), keyCode: keyCode)
            if code >= 0xF700 {
                modifiers.insert(.function)
            }
        } else if key.count == 1 {
            self.init(characters: key, keyCode: Self.keyCodes[Character(key)] ?? 0)
            // "ru+ctrl+d": the same key typed with the Russian – PC layout active ("в";
            // "`" is "]" there on ISO keyboards, "ё" on ANSI ones).
            if russian, let typed = KeyboardLayout.character(keyCode: keyCode, onLayout: "com.apple.keylayout.RussianWin")
                ?? Self.russian[Character(key)].map(String.init) {
                characters = typed
                charactersIgnoringModifiers = typed
                isRussian = true
            }
        } else {
            return nil
        }
        self.modifiers = modifiers
    }
}
/// Writes the placeholder's contents when a coordinated reader asks (as Microsoft
/// Remote Desktop does with the files it puts on the clipboard).
nonisolated private final class LazyFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let source: URL

    init(placeholder: URL, source: URL) {
        presentedItemURL = placeholder
        self.source = source
    }

    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        guard let placeholder = presentedItemURL else { return completionHandler(nil) }
        completionHandler(Result { try Data(contentsOf: source).write(to: placeholder) }.error)
    }
}

nonisolated private extension Result where Failure == Error {
    var error: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
#endif
