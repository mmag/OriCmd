import AppKit

/// The app's settings store. Debug test runs (see `DebugAutomation`) use a
/// separate suite so they never touch the user's own settings.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if DebugAutomation.initialDirectory(left: true) != nil,
           let tests = UserDefaults(suiteName: "ru.themmag.OriCmd.tests") {
            return tests
        }
        #endif
        return .standard
    }()

    /// The clipboard for files; test runs use a private one so they never
    /// replace what the user has copied.
    static let pasteboard: NSPasteboard = {
        #if DEBUG
        if DebugAutomation.initialDirectory(left: true) != nil {
            return NSPasteboard(name: NSPasteboard.Name("ru.themmag.OriCmd.tests"))
        }
        #endif
        return .general
    }()
}
