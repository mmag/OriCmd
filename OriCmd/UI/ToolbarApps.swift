import AppKit

/// Applications put on the button bar by dragging them there, as programs on
/// the button bar of a classic two-panel manager: a click starts one, files
/// dropped on its button open in it. The bar's own saved configuration is the
/// list of them; they are not offered in the Customize palette, so one taken
/// off the bar is gone.
enum ToolbarApps {
    private static let prefix = "app."

    static func identifier(for path: String) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(prefix + path)
    }

    static func path(from identifier: NSToolbarItem.Identifier) -> String? {
        identifier.rawValue.hasPrefix(prefix) ? String(identifier.rawValue.dropFirst(prefix.count)) : nil
    }

    /// An application bundle: a folder (or a link to one) named *.app.
    static func isApplication(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
            && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// "Safari" for /Applications/Safari.app.
    static func name(of path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? (name as NSString).deletingPathExtension : name
    }
}

/// The button of an application on the button bar.
final class AppButton: NSButton {
    let path: String
    var onRemove: ((String) -> Void)?

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 20, height: 20)
        image = icon
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        bezelStyle = .toolbar
        toolTip = ToolbarApps.name(of: path)
        setAccessibilityLabel(toolTip)
        target = self
        action = #selector(launch(_:))
        registerForDraggedTypes([.fileURL])
        widthAnchor.constraint(equalToConstant: 34).isActive = true

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open"), action: #selector(launch(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Show in Finder"), action: #selector(showInFinder(_:)),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Remove from Button Bar"), action: #selector(remove(_:)),
                     keyEquivalent: "").target = self
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func launch(_ sender: Any?) {
        NSWorkspace.shared.openApplication(at: URL(filePath: path, directoryHint: .isDirectory),
                                           configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: failureHandler())
    }

    /// Reports a failed start (the application was moved or deleted, …) over
    /// the main window: in full screen the toolbar is in a window of its own.
    private func failureHandler() -> @Sendable (NSRunningApplication?, Error?) -> Void {
        let name = ToolbarApps.name(of: path)
        let window = NSApp.mainWindow ?? self.window
        return { _, error in
            guard let error else { return }
            Task { @MainActor in
                Prompt.error(String(localized: "Cannot open \u{201C}\(name)\u{201D}"), error, in: window)
            }
        }
    }

    @objc private func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    @objc private func remove(_ sender: Any?) {
        onRemove?(path)
    }

    // MARK: - Files dropped on the button open in the application

    private func files(in info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL]) ?? []
    }

    /// A button whose application is gone takes nothing.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(in: sender).isEmpty || !FileManager.default.fileExists(atPath: path) ? [] : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(in: sender)
        guard !urls.isEmpty else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: URL(filePath: path, directoryHint: .isDirectory),
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: failureHandler())
        return true
    }
}

/// The main window: applications dropped on its toolbar become buttons.
final class MainWindow: NSWindow, NSDraggingDestination {
    var onDropApplications: (([URL]) -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // The toolbar takes right clicks for its own "Customize Toolbar" menu before
        // its buttons see them. Watched for the whole application, not in sendEvent:
        // in full screen the toolbar is in a window of its own. The main window lives
        // as long as the application, so the monitor is never removed.
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            self?.showAppButtonMenu(for: event) == true ? nil : event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A terminal under a panel tells its panel when it gets the focus (SwiftTerm's
    /// view does not let subclasses see that).
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let terminal = responder as? ShellTerminalView {
            (terminal.superview as? TerminalPane)?.onFocus?()
        }
        return accepted
    }

    /// Shows the menu of the application button under a right (or Control-) click,
    /// unless a sheet or a modal window is open. Returns whether it did.
    func showAppButtonMenu(for event: NSEvent) -> Bool {
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick, attachedSheet == nil, NSApp.modalWindow == nil, let eventWindow = event.window,
              let button = toolbar?.items.lazy.compactMap({ $0.view as? AppButton }).first(where: { button in
                  button.window === eventWindow && !button.isHiddenOrHasHiddenAncestor
                      && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
              }),
              let menu = button.menu else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
        return true
    }

    private func applications(in info: NSDraggingInfo) -> [URL] {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL]) ?? []
        return urls.filter(ToolbarApps.isApplication)
    }

    /// The toolbar, when shown, is the part of the window above the content.
    private func isOverToolbar(_ info: NSDraggingInfo) -> Bool {
        toolbar?.isVisible == true && info.draggingLocation.y >= contentLayoutRect.maxY
    }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        guard isOverToolbar(info), !applications(in: info).isEmpty else { return [] }
        return info.draggingSourceOperationMask.contains(.link) ? .link : .generic
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !operation(for: sender).isEmpty else { return false }
        onDropApplications?(applications(in: sender))
        return true
    }
}
