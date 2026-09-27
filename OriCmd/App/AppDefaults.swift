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
