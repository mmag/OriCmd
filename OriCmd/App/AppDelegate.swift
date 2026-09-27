import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        for name in [KeyBindings.didChange, UserCommands.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.mainMenu = MainMenu.make() }
            }
        }

        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        #if DEBUG
        if let window = controller.window { DebugAutomation.run(in: window) }
        #endif

        NSApp.activate()
        // A little after launch, so the first look is not an alert.
        Task {
            try? await Task.sleep(for: .seconds(5))
            Updater.checkIfDue(window: mainWindowController?.window)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.check(interactive: true, window: mainWindowController?.window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func showStartMenuEditor(_ sender: Any?) {
        UserCommandsWindowController.shared.showWindow(sender)
    }

    /// Programs for Enter / F3 / F4 by file mask.
    @objc(cm_InternalAssociate:)
    func showAssociations(_ sender: Any?) {
        AssociationsWindowController.shared.showWindow(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    @objc(cm_Exit:)
    func exit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
