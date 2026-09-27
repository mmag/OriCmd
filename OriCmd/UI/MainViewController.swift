import AppKit

/// Root view of the main window: two panels side by side,
/// the command line and the function key bar underneath.
final class MainViewController: NSViewController {
    private let leftPanel: FilePanelController
    private let rightPanel: FilePanelController
    private let splitView = NSSplitView()
    private let commandLine = CommandLineView()
    private let functionKeyBar = FunctionKeyBar()

    private var didAppear = false

    private static let showHiddenKey = "ShowHiddenFiles"

    /// Hidden files are shown or hidden in both panels at once, as in Total Commander.
    private var showsHidden = UserDefaults.standard.bool(forKey: showHiddenKey) {
        didSet {
            UserDefaults.standard.set(showsHidden, forKey: Self.showHiddenKey)
            leftPanel.showsHidden = showsHidden
            rightPanel.showsHidden = showsHidden
        }
    }

    private(set) var activePanel: FilePanelController

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var left = home
        var right = home
        #if DEBUG
        left = DebugAutomation.initialDirectory(left: true) ?? left
        right = DebugAutomation.initialDirectory(left: false) ?? right
        #endif
        leftPanel = FilePanelController(directory: left)
        rightPanel = FilePanelController(directory: right)
        activePanel = leftPanel
        super.init(nibName: nil, bundle: nil)
        addChild(leftPanel)
        addChild(rightPanel)
        leftPanel.delegate = self
        rightPanel.delegate = self
        leftPanel.showsHidden = showsHidden
        rightPanel.showsHidden = showsHidden

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(volumesDidChange(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var inactivePanel: FilePanelController {
        activePanel === leftPanel ? rightPanel : leftPanel
    }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(leftPanel.view)
        splitView.addArrangedSubview(rightPanel.view)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        for view in [splitView, commandLine, functionKeyBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            commandLine.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            commandLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            functionKeyBar.topAnchor.constraint(equalTo: commandLine.bottomAnchor),
            functionKeyBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            functionKeyBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            functionKeyBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        activate(leftPanel)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didAppear {
            didAppear = true
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
            activePanel.focus()
        }
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        leftPanel.volumesDidChange()
        rightPanel.volumesDidChange()
    }

    /// Panel commands reach the active panel even when the command line has focus.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if activePanel.responds(to: action) { return activePanel }
        if activePanel.listView.responds(to: action) { return activePanel.listView }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    private func activate(_ panel: FilePanelController) {
        activePanel = panel
        leftPanel.isActive = panel === leftPanel
        rightPanel.isActive = panel === rightPanel
        commandLine.directory = panel.directory
    }
}

// MARK: - Commands

extension MainViewController: NSMenuItemValidation {
    @objc(cm_SwitchHidSys:)
    func switchHidSys(_ sender: Any?) {
        showsHidden.toggle()
    }

    /// Ctrl+U: swaps the directories (and sort orders) of the two panels.
    @objc(cm_Exchange:)
    func exchange(_ sender: Any?) {
        let left = (leftPanel.directory, leftPanel.listView.currentItem?.name, leftPanel.sortOrder)
        let right = (rightPanel.directory, rightPanel.listView.currentItem?.name, rightPanel.sortOrder)
        leftPanel.sortOrder = right.2
        rightPanel.sortOrder = left.2
        leftPanel.load(right.0, selecting: right.1)
        rightPanel.load(left.0, selecting: left.1)
    }

    /// F5: copies the selection of the active panel, by default into the other panel.
    @objc(cm_Copy:)
    func copyFiles(_ sender: Any?) {
        askForTransfer(.copy)
    }

    /// F6: moves or renames the selection of the active panel.
    @objc(cm_RenMov:)
    func moveFiles(_ sender: Any?) {
        askForTransfer(.move)
    }

    private func askForTransfer(_ kind: TransferJob.Kind) {
        let source = activePanel
        let items = source.selectedItems
        guard !items.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        let what = items.count == 1 ? "\u{201C}\(items[0].name)\u{201D}" : "\(items.count) files/folders"
        let targetPath = inactivePanel.directory.path
        let initial = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
        Prompt.text(kind == .copy ? "Copy" : "Move/Rename",
                    message: kind == .copy ? "Copy \(what) to:" : "Rename/move \(what) to:",
                    initial: initial, okTitle: kind == .copy ? "Copy" : "Move", in: window) { [weak self] text in
            self?.transfer(kind, items: items, from: source, to: text)
        }
    }

    private func transfer(_ kind: TransferJob.Kind, items: [FileItem], from source: FilePanelController, to text: String) {
        guard let window = view.window, !text.isEmpty else { return }
        let (destination, newName) = Self.resolveTarget(text, itemCount: items.count, base: source.directory)
        let job = TransferJob(kind: kind, sources: items.map(\.url), destination: destination, newName: newName)
        Task {
            let done = await TransferController(job: job, window: window).run()
            source.listView.setMarked(source.listView.marked.subtracting(done.map(\.lastPathComponent)))
            leftPanel.reread()
            rightPanel.reread()
        }
    }

    /// Interprets the target typed in the copy/move dialog: an existing folder or a
    /// path ending in "/" receives the items; otherwise a single item gets that name.
    /// Relative paths are relative to the source folder.
    static func resolveTarget(_ text: String, itemCount: Int, base: URL) -> (destination: URL, newName: String?) {
        var path = (text as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = base.appending(path: path).path
        }
        let url = URL(filePath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if text.hasSuffix("/") || (exists && isDirectory.boolValue) || itemCount > 1 {
            return (url, nil)
        }
        return (url.deletingLastPathComponent(), url.lastPathComponent)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == Command.switchHidSys.selector {
            menuItem.state = showsHidden ? .on : .off
        }
        return true
    }
}

extension MainViewController: FilePanelControllerDelegate {
    func filePanelDidBecomeActive(_ panel: FilePanelController) {
        activate(panel)
    }

    func filePanelSwitchPanel(_ panel: FilePanelController) {
        (panel === leftPanel ? rightPanel : leftPanel).focus()
    }

    func filePanelDidChangeDirectory(_ panel: FilePanelController) {
        if panel === activePanel {
            commandLine.directory = panel.directory
        }
    }
}
