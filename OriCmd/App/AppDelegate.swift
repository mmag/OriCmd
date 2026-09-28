import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.applyAppearance()
        Task { await Self.removeOldTemporaryFolders() }
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

    /// Files opened from archives and servers are unpacked or downloaded into
    /// "OriCmd-…" temporary folders; those older than a day are removed.
    @concurrent
    private nonisolated static func removeOldTemporaryFolders() async {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
        let limit = Date().addingTimeInterval(-24 * 60 * 60)
        let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where item.lastPathComponent.hasPrefix("OriCmd-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < limit {
                try? manager.removeItem(at: item)
            }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.check(interactive: true, window: mainWindowController?.window)
    }

    /// An interrupted copy leaves only a hidden partial file, but the rest of the
    /// operation is lost: quitting asks while operations run or wait in the queue.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = TransferController.runningCount + TransferQueue.shared.waitingCount
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "File operations are still running")
        alert.informativeText = String(localized: "Quitting stops them; files not copied yet stay where they were.")
        alert.addButton(withTitle: String(localized: "Continue Working"))
        let quit = alert.addButton(withTitle: String(localized: "Quit Anyway"))
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
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
