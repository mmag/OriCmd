import AppKit

/// The app's settings store. Debug test runs (see `DebugAutomation`) use a
/// separate suite so they never touch the user's own settings.
enum AppDefaults {
    /// A Debug run driven by `DebugAutomation` on test folders.
    static var isTestRun: Bool {
        #if DEBUG
        DebugAutomation.initialDirectory(left: true) != nil
        #else
        false
        #endif
    }

    /// The defaults domain behind `store` (for values that must live in it
    /// rather than be inherited from the global domain, like AppleLanguages).
    static var domainName: String {
        isTestRun ? "ru.themmag.OriCmd.tests" : Bundle.main.bundleIdentifier ?? "ru.themmag.OriCmd"
    }

    static let store: UserDefaults = {
        #if DEBUG
        if isTestRun, let tests = UserDefaults(suiteName: "ru.themmag.OriCmd.tests") {
            return tests
        }
        #endif
        return .standard
    }()

    /// The clipboard for files; test runs use a private one so they never
    /// replace what the user has copied.
    static let pasteboard: NSPasteboard = {
        if isTestRun {
            return NSPasteboard(name: NSPasteboard.Name("ru.themmag.OriCmd.tests"))
        }
        return .general
    }()
}

extension NSWindow {
    /// Restores the frame saved under `name` and keeps saving it — except in
    /// test runs, which must neither use nor change the user's window frames.
    /// Returns whether a saved frame was applied. Called once the window
    /// controller has the window: `NSWindowController.init(window:)` clears the
    /// window's autosave name, and the frame was then never saved.
    ///
    /// AppKit's own autosave does not keep the frame of a tiled or filled window
    /// (Window ▸ Fill, a double click on the title bar) as it is: the frame the
    /// window really has is saved as well, and wins.
    @discardableResult
    func rememberFrame(as name: String) -> Bool {
        guard !AppDefaults.isTestRun else { return false }
        var restored = false
        if let saved = AppDefaults.store.string(forKey: Self.frameKey(name)) {
            let frame = NSRectFromString(saved)
            // Not on a screen that is gone, nor smaller than the window may be.
            if frame.width >= minSize.width, frame.height >= minSize.height,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                setFrame(constrainFrameRect(frame, to: screen), display: false)
                restored = true
            }
        }
        if !restored {
            restored = setFrameUsingName(name)
        }
        setFrameAutosaveName(name)
        for notification in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(saveRememberedFrame(_:)),
                                                   name: notification, object: self)
        }
        return restored
    }

    /// Only the window that holds the autosave name saves (as with AppKit's own),
    /// and not in full screen, whose frame is the screen's.
    @objc private func saveRememberedFrame(_ notification: Notification) {
        guard !frameAutosaveName.isEmpty, !styleMask.contains(.fullScreen), !isMiniaturized else { return }
        AppDefaults.store.set(NSStringFromRect(frame), forKey: Self.frameKey(frameAutosaveName))
    }

    private static func frameKey(_ name: String) -> String {
        "WindowFrame \(name)"
    }
}
