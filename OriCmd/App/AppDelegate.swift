import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        #if DEBUG
        if let window = controller.window { DebugAutomation.run(in: window) }
        #endif

        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc(cm_Exit:)
    func exit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
