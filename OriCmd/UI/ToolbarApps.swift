import AppKit

/// Applications put on the button bar by dragging them there, as programs on
/// the button bar of a classic two-panel manager: a click starts one, files
/// dropped on its button open in it.
enum ToolbarApps {
    private static let key = "ToolbarApps"
    private static let prefix = "app."

    /// Paths of the applications, in the order they were added.
    static var all: [String] {
        get { AppDefaults.store.stringArray(forKey: key) ?? [] }
        set { AppDefaults.store.set(newValue, forKey: key) }
    }

    static func identifier(for path: String) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(prefix + path)
    }

    static func path(from identifier: NSToolbarItem.Identifier) -> String? {
        identifier.rawValue.hasPrefix(prefix) ? String(identifier.rawValue.dropFirst(prefix.count)) : nil
    }

    static func isApplication(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
    }

    static func name(of path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
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
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let window = self.window
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in
                Prompt.error(String(localized: "Cannot open \u{201C}\(ToolbarApps.name(of: url.path))\u{201D}"), error, in: window)
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(in: sender).isEmpty ? [] : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(in: sender)
        guard !urls.isEmpty else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: URL(filePath: path, directoryHint: .isDirectory),
                                configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// The main window: applications dropped on its toolbar become buttons.
final class MainWindow: NSWindow, NSDraggingDestination {
    var onDropApplications: (([URL]) -> Void)?

    private func applications(in info: NSDraggingInfo) -> [URL] {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL]) ?? []
        return urls.filter(ToolbarApps.isApplication)
    }

    /// The toolbar is the part of the window above the content.
    private func isOverToolbar(_ info: NSDraggingInfo) -> Bool {
        info.draggingLocation.y >= contentLayoutRect.maxY
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
