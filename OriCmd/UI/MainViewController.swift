import AppKit
import os

/// Root view of the main window: two panels side by side,
/// the command line and the function key bar underneath.
final class MainViewController: NSViewController {
    private let leftPanel: FilePanelController
    private let rightPanel: FilePanelController
    private let splitView = PanelSplitView()
    /// Show → Separate Tree: a folder tree left of the panels, for the active one.
    private var separateTree: DirectoryTreePanel?
    private var splitViewLeading: NSLayoutConstraint!
    private static let separateTreeWidth: CGFloat = 220
    private static let splitRatioKey = "PanelSplitRatio"
    private let commandLine = CommandLineController()
    private let functionKeyBar = FunctionKeyBar()

    private var didAppear = false
    private var commandLineHeight: NSLayoutConstraint!
    private var functionKeyBarHeight: NSLayoutConstraint!

    /// Ctrl+Q preview shown in place of `quickViewReplaces`' view.
    private var quickView: QuickViewPanel?
    /// Total Commander's synchronous directory changes: entering a subfolder or
    /// going up in one panel does the same in the other.
    private var syncsDirectoryChanges = false
    private var lastDirectories: [ObjectIdentifier: URL] = [:]
    private var quickViewReplaces: FilePanelController?

    /// Ctrl+F8 folder tree shown in place of `treeReplaces`' view.
    private var treePanel: DirectoryTreePanel?
    private var treeReplaces: FilePanelController?

    private static let showHiddenKey = "ShowHiddenFiles"
    private static let leftPanelKey = "LeftPanel"
    private static let rightPanelKey = "RightPanel"

    /// Hidden files are shown or hidden in both panels at once, as in Total Commander.
    private var showsHidden = AppDefaults.store.bool(forKey: showHiddenKey) {
        didSet {
            AppDefaults.store.set(showsHidden, forKey: Self.showHiddenKey)
            leftPanel.showsHidden = showsHidden
            rightPanel.showsHidden = showsHidden
        }
    }

    private(set) var activePanel: FilePanelController

    init() {
        var leftOverride: URL?
        var rightOverride: URL?
        #if DEBUG
        leftOverride = DebugAutomation.initialDirectory(left: true)
        rightOverride = DebugAutomation.initialDirectory(left: false)
        #endif
        leftPanel = Self.restoredPanel(Self.leftPanelKey, override: leftOverride)
        rightPanel = Self.restoredPanel(Self.rightPanelKey, override: rightOverride)
        activePanel = leftPanel
        super.init(nibName: nil, bundle: nil)
        addChild(leftPanel)
        addChild(rightPanel)
        leftPanel.delegate = self
        rightPanel.delegate = self
        commandLine.delegate = self
        leftPanel.showsHidden = showsHidden
        rightPanel.showsHidden = showsHidden

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(volumesDidChange(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange(_:)),
                                               name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var panels: [FilePanelController] { [leftPanel, rightPanel] }

    var inactivePanel: FilePanelController {
        activePanel === leftPanel ? rightPanel : leftPanel
    }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(leftPanel.view)
        splitView.addArrangedSubview(rightPanel.view)
        splitView.delegate = self
        splitView.onDoubleClickDivider = { [weak self] in self?.splitView.setRatio(0.5) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        for view in [splitView, commandLine.view, functionKeyBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        splitViewLeading = splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        splitViewLeading.isActive = true
        commandLineHeight = commandLine.view.heightAnchor.constraint(equalToConstant: CommandLineView.height)
        functionKeyBarHeight = functionKeyBar.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            commandLineHeight,
            functionKeyBarHeight,
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            commandLine.view.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            commandLine.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandLine.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            functionKeyBar.topAnchor.constraint(equalTo: commandLine.view.bottomAnchor),
            functionKeyBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            functionKeyBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            functionKeyBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        activate(leftPanel)
        applyLayoutSettings()
        applySeparateTree()
        applyPanelArrangement()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        applyLayoutSettings()
        applySeparateTree()
        applyPanelArrangement()
        leftPanel.settingsDidChange()
        rightPanel.settingsDidChange()
    }

    /// Shows or hides the command line and the function key bar.
    private func applyLayoutSettings() {
        commandLine.view.isHidden = !Settings.showsCommandLine
        commandLineHeight.constant = Settings.showsCommandLine ? CommandLineView.height : 0
        functionKeyBar.isHidden = !Settings.showsFunctionKeys
        functionKeyBarHeight.constant = Settings.showsFunctionKeys ? 22 : 0
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didAppear {
            didAppear = true
            let saved = AppDefaults.store.double(forKey: Self.splitRatioKey)
            splitView.setRatio(saved > 0.05 && saved < 0.95 ? saved : 0.5)
            activePanel.focus()
        }
    }

    /// Recreates a panel with the tabs saved at the last launch (skipping vanished folders).
    private static func restoredPanel(_ key: String, override: URL?) -> FilePanelController {
        if let override {
            return FilePanelController(tabDirectories: [override])
        }
        let state = AppDefaults.store.dictionary(forKey: key)
        let viewMode = (state?["view"] as? String).flatMap(FileListView.ViewMode.init(rawValue:)) ?? .full
        let (tabs, active) = FilePanelController.SavedTabs(state).tabs(sortOrder: SortOrder())
        let panel = FilePanelController(tabs: tabs, activeTab: active)
        panel.viewMode = viewMode
        panel.chosenColumnSet = state?["columnSet"] as? String
        return panel
    }

    private func savePanels() {
        for (panel, key) in [(leftPanel, Self.leftPanelKey), (rightPanel, Self.rightPanelKey)] {
            var state = panel.tabState.dictionary.merging(["view": panel.viewMode.rawValue]) { $1 }
            state["columnSet"] = panel.chosenColumnSet
            AppDefaults.store.set(state, forKey: key)
        }
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        for panel in panels {
            // Panels on a renamed volume follow it rather than leave its old path.
            if notification.name == NSWorkspace.didRenameVolumeNotification,
               let old = notification.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL,
               let new = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
               panel.volumeWasRenamed(from: old, to: new) {
                continue
            }
            panel.volumesDidChange()
        }
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
        commandLine.view.directory = panel.directory
        separateTree?.reveal(panel.directory, quietly: true)
    }

    #if DEBUG
    /// The separate tree, for the test harness.
    var separateTreeForTests: DirectoryTreePanel? { separateTree }
    #endif

    /// The tree of the Alt+F10 dialog while it is open (for the test harness).
    private(set) var folderTreeDialog: DirectoryTreePanel?

    /// Alt+F10 (cm_CDtree): a folder tree in a dialog, the active panel's folder
    /// selected; typing finds a folder, Enter (or OK) goes there.
    @objc(cm_CDtree:)
    func cdTree(_ sender: Any?) {
        guard let window = view.window, activePanel.remote == nil else {
            NSSound.beep()
            return
        }
        let tree = DirectoryTreePanel(root: URL(filePath: "/"), showsHidden: showsHidden, insets: (0, 0))
        tree.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to Folder")
        alert.informativeText = String(localized: "Type a folder's first letters to find it.")
        alert.accessoryView = tree
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addCancelButton()
        tree.onSwitchPanel = { [weak alert] in
            guard let alert else { return }
            window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
        tree.onClose = { [weak alert] _ in
            guard let alert else { return }
            window.endSheet(alert.window, returnCode: .cancel)
        }
        folderTreeDialog = tree
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            folderTreeDialog = nil
            if response == .alertFirstButtonReturn, let url = tree.selectedURL {
                activePanel.load(url)
            }
            activePanel.focus()
        }
        tree.reveal(activePanel.directory, quietly: true)
        tree.focus()
    }

    /// Net → Download from URL…: http(s) and ftp addresses, one per line (the one
    /// on the clipboard offered), downloaded into the active panel's folder.
    @objc func downloadFromURL(_ sender: Any?) {
        guard let window = view.window, activePanel.archive == nil, activePanel.remote == nil else {
            NSSound.beep()
            return
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        let clipboard = AppDefaults.pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text.string = ["http://", "https://", "ftp://"].contains(where: clipboard.lowercased().hasPrefix) ? clipboard : ""
        text.font = Theme.panelFont
        text.isRichText = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.identifier = NSUserInterfaceItemIdentifier("downloadURLs")
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let alert = NSAlert()
        alert.messageText = String(localized: "Download from URL")
        alert.informativeText = String(localized: "Addresses (http, https, ftp), one per line, into \(activePanel.directory.path):")
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addCancelButton()
        alert.window.initialFirstResponder = text
        let panel = activePanel
        let folder = panel.directory
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let urls = text.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .compactMap(URL.init(string:)).filter { ["http", "https", "ftp"].contains($0.scheme?.lowercased() ?? "") }
            guard !urls.isEmpty else {
                NSSound.beep()
                return
            }
            confirmOverwriting(urls.map(URLDownloader.fileName(of:)), in: folder) {
                Task {
                    let controller = TransferController(title: String(localized: "Downloading"),
                                                        failureTitle: String(localized: "Download failed"), window: window)
                    let files = await controller.run(source: urls[0].absoluteString, target: folder.path) { progress, _ in
                        try await URLDownloader.download(urls, into: folder, progress: progress)
                    }
                    panel.reread()
                    if let first = files.first { panel.load(folder, selecting: first.lastPathComponent) }
                }
            }
        }
    }

    /// Show → Use the Ignore List (cm_SwitchIgnoreList).
    @objc(cm_SwitchIgnoreList:)
    func switchIgnoreList(_ sender: Any?) {
        Settings.usesIgnoreList.toggle()
    }

    /// Show → Ignore List…: the names, masks and paths to leave out, a line each;
    /// saving it turns it on.
    @objc func editIgnoreList(_ sender: Any?) {
        guard let window = view.window else { return }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        text.string = Settings.ignoreList.joined(separator: "\n")
        text.font = Theme.panelFont
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.identifier = NSUserInterfaceItemIdentifier("ignoreList")
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let alert = NSAlert()
        alert.messageText = String(localized: "Ignore List")
        alert.informativeText = String(localized:
            "Entries the panels leave out: a name, a mask (*.bak) or a full path (~/Library) per line.")
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addCancelButton()
        alert.window.initialFirstResponder = text
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Settings.ignoreList = text.string.components(separatedBy: .newlines)
            Settings.usesIgnoreList = true
        }
    }

    /// Show → Horizontal Panels (cm_HorizontalPanels): the panels one above the other.
    @objc(cm_HorizontalPanels:)
    func horizontalPanels(_ sender: Any?) {
        Settings.panelsOneAboveTheOther.toggle()
    }

    /// Side by side, or one above the other; the share of each stays.
    private func applyPanelArrangement() {
        let vertical = !Settings.panelsOneAboveTheOther
        guard splitView.isVertical != vertical else { return }
        let ratio = splitView.ratio
        splitView.isVertical = vertical
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        splitView.setRatio(ratio)
    }

    /// Show → Separate Tree (cm_ToggleSeparateTree1): one tree for both panels.
    @objc(cm_ToggleSeparateTree1:)
    func toggleSeparateTree1(_ sender: Any?) {
        Settings.showsSeparateTree.toggle()
    }

    /// Shows or removes the separate tree. A folder chosen in it is shown in the
    /// active panel, and it follows the active panel's folder.
    private func applySeparateTree() {
        if Settings.showsSeparateTree, separateTree == nil {
            let tree = DirectoryTreePanel(root: URL(filePath: "/"), showsHidden: showsHidden)
            tree.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tree)
            NSLayoutConstraint.activate([
                tree.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tree.topAnchor.constraint(equalTo: splitView.topAnchor),
                tree.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
                tree.widthAnchor.constraint(equalToConstant: Self.separateTreeWidth),
            ])
            splitViewLeading.constant = Self.separateTreeWidth + 1
            tree.onSelect = { [weak self] url in self?.activePanel.load(url) }
            tree.onSwitchPanel = { [weak self] in self?.activePanel.focus() }
            tree.onClose = { [weak self] mode in
                self?.activePanel.viewMode = mode
                self?.activePanel.focus()
            }
            separateTree = tree
            tree.reveal(activePanel.directory, quietly: true)
        } else if !Settings.showsSeparateTree, let tree = separateTree {
            if view.window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: tree) == true }) == true {
                activePanel.focus()
            }
            tree.removeFromSuperview()
            separateTree = nil
            splitViewLeading.constant = 0
        }
    }
}

// MARK: - Commands

extension MainViewController: NSMenuItemValidation {
    @objc(cm_SwitchHidSys:)
    func switchHidSys(_ sender: Any?) {
        showsHidden.toggle()
    }

    /// Ctrl+U: swaps the directories (and sort orders) of the two panels.
    /// Ctrl+U: swaps the panels' folders (servers are left first, which may be cancelled).
    @objc(cm_Exchange:)
    func exchange(_ sender: Any?) {
        if leftPanel.remote != nil || rightPanel.remote != nil {
            leftPanel.leaveServer { [weak self] in
                self?.rightPanel.leaveServer { self?.exchange(sender) }
            }
            return
        }
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
        if source.remote != nil || inactivePanel.remote != nil {
            askForServerTransfer(items, kind: kind, from: source, to: inactivePanel)
            return
        }
        if let target = inactivePanel.archive, source.archive == nil, target.isWritable {
            askForPacking(items, kind: kind, from: source, into: target)
            return
        }
        if inactivePanel.archive != nil || (source.archive != nil && kind == .move) {
            Prompt.info(String(localized: "Not supported inside archives"),
                        message: String(localized: "Unpack the files first (F5), or use Alt+F5 to create a new archive."),
                        in: window)
            return
        }
        if let archive = source.archive {
            askForUnpacking(items, from: archive, in: source)
            return
        }
        let target = inactivePanel
        let targetFolders = target.searchResultsShown ? [] : target.listView.items
            .filter { $0.isFolder && !$0.isParent && target.listView.marked.contains($0.name) }
            .map(\.url)
        let folders = items.filter(\.isFolder).count
        CopyDialog.show(kind: kind, files: items.count - folders, folders: folders,
                        target: Self.folderText(target.directory), selectedTargetFolders: targetFolders.count,
                        in: window) { [weak self] result in
            self?.transfer(result, items: items, from: source, targetFolders: result.toAllSelectedFolders ? targetFolders : [])
        }
    }

    /// Runs the copy or move chosen in the F5/F6 dialog (once per selected folder
    /// of the target panel with "Copy to all selected folders").
    private func transfer(_ result: CopyDialog.Result, items: [FileItem], from source: FilePanelController,
                          targetFolders: [URL]) {
        guard let window = view.window else { return }
        var jobs: [TransferJob]
        if targetFolders.isEmpty {
            let (destination, newName, mask) = Self.resolveTarget(result.target, itemCount: items.count, base: source.directory,
                                                                  source: items.count == 1 ? items[0].url : nil)
            var options = result.options
            options.renameMask = mask
            jobs = [TransferJob(kind: result.kind, sources: items.map(\.url), destination: destination, newName: newName,
                                options: options)]
        } else {
            // Moving can only happen once; the other folders get copies.
            jobs = targetFolders.enumerated().map { index, folder in
                let isLast = index == targetFolders.count - 1
                return TransferJob(kind: result.kind == .move && isLast ? .move : .copy, sources: items.map(\.url),
                                   destination: folder, newName: nil, options: result.options)
            }
        }
        let operation = { [weak self] in
            // Unmarked are the items that reached every target.
            var transferred: Set<URL>?
            for job in jobs {
                let done = Set(await TransferController.run(job, in: window, inBackground: result.queued))
                transferred = transferred.map { $0.intersection(done) } ?? done
            }
            let finished = transferred ?? []
            source.listView.setMarked(source.listView.marked.subtracting(
                items.filter { finished.contains($0.url) }.map(\.name)))
            self?.leftPanel.reread()
            self?.rightPanel.reread()
        }
        if result.queued {
            TransferQueue.shared.add(operation)
        } else {
            Task { await operation() }
        }
    }

    // MARK: - Servers

    /// F5/F6 with a server in one panel: downloads to, or uploads from, the other panel.
    private func askForServerTransfer(_ items: [FileItem], kind: TransferJob.Kind, from source: FilePanelController,
                                      to target: FilePanelController) {
        guard let window = view.window else { return }
        guard (source.remote == nil) != (target.remote == nil), source.archive == nil, target.archive == nil,
              target.searchResultsShown == false else {
            Prompt.info(String(localized: "Not supported on servers"),
                        message: String(localized: "Copy between a server and a local folder."), in: window)
            return
        }
        let what = items.count == 1 ? String(localized: "\u{201C}\(items[0].name)\u{201D}")
            : String(localized: "\(items.count) files/folders")
        if source.remote != nil {
            Prompt.text(kind == .copy ? String(localized: "Download") : String(localized: "Download and delete"),
                        message: String(localized: "Download \(what) to:"),
                        initial: Self.folderText(target.directory),
                        okTitle: String(localized: "Download"), in: window) { text in
                guard !text.isEmpty else { return }
                let folder = Self.resolveFolder(text, base: target.directory)
                Task {
                    if await source.download(items, to: folder, moving: kind == .move) {
                        target.reread()
                    }
                }
            }
        } else if let remote = target.remote {
            Prompt.confirm(kind == .copy ? String(localized: "Upload \(what) to \(remote.displayPath)?")
                                         : String(localized: "Move \(what) to \(remote.displayPath)?"),
                           okTitle: String(localized: "Upload"), in: window) {
                target.upload(items.map(\.url), moving: kind == .move)
                if kind == .move {
                    source.listView.setMarked([])
                }
            }
        }
    }

    // MARK: - Archives

    /// F5 inside an archive: unpacks the selected entries, by default into the other panel.
    private func askForUnpacking(_ items: [FileItem], from archive: FilePanelController.ArchiveLocation,
                                 in source: FilePanelController) {
        guard let window = view.window else { return }
        let what = items.count == 1 ? String(localized: "\u{201C}\(items[0].name)\u{201D}")
            : String(localized: "\(items.count) files/folders")
        Prompt.text(String(localized: "Unpack"), message: String(localized: "Unpack \(what) to:"),
                    initial: Self.folderText(inactivePanel.directory), okTitle: String(localized: "Unpack"),
                    in: window) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let destination = Self.resolveFolder(text, base: source.directory)
            let paths = items.map { archive.path(of: $0.name) }
            let entries = ArchivePasswords.entries(archive.entries, at: paths)
            let total = entries.reduce(Int64(0)) { $0 + $1.size }
            confirmOverwriting(items.map(\.name), in: destination) {
                Task {
                    guard let passwords = await self.passwords(for: [(archive.url, entries)]) else { return }
                    self.unpack([(archive.url, paths, archive.folder, destination, passwords[archive.url])], total: total)
                }
            }
        }
    }

    /// F5/F6 towards a panel showing an archive: adds the selection to it
    /// (and, for F6, deletes the originals afterwards).
    private func askForPacking(_ items: [FileItem], kind: TransferJob.Kind, from source: FilePanelController,
                               into archive: FilePanelController.ArchiveLocation) {
        guard let window = view.window else { return }
        let target = inactivePanel
        let what = items.count == 1 ? String(localized: "\u{201C}\(items[0].name)\u{201D}")
            : String(localized: "\(items.count) files/folders")
        let place = String(localized: "\u{201C}\(archive.url.lastPathComponent)\u{201D}")
        let existing = Set(target.listView.items.map(\.name)).intersection(items.map(\.name))
        Prompt.confirm(kind == .copy ? String(localized: "Pack \(what) into \(place)?")
                                     : String(localized: "Move \(what) into \(place)?"),
                       message: existing.isEmpty ? "" : String(localized: "Entries with the same names will be replaced."),
                       okTitle: kind == .copy ? String(localized: "Pack") : String(localized: "move.button", defaultValue: "Move"),
                       in: window) {
            target.applyArchiveEdit(.add(items.map(\.url), folder: archive.folder), selecting: items.first?.name) {
                succeeded in
                guard succeeded else { return }
                source.listView.setMarked(source.listView.marked.subtracting(items.map(\.name)))
                guard kind == .move else { return }
                Task {
                    do {
                        try await FileOperations.deletePermanently(items.map(\.url))
                    } catch {
                        Prompt.error(String(localized: "Cannot delete"), error, in: window)
                    }
                    source.reread()
                }
            }
        }
    }

    // MARK: - Column sets

    /// Show → Columns → Column Sets…: the sets, their columns and folders.
    @objc func configureColumnSets(_ sender: Any?) {
        ColumnSetsWindowController.show()
    }

    // MARK: - Favorite tabs

    /// Shows the favorite tabs chosen in the menu in both panels.
    @objc func showFavoriteTabs(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let favorite = FavoriteTabs.saved.first(where: { $0.name == name }) else { return }
        leftPanel.replaceTabs(with: favorite.left)
        rightPanel.replaceTabs(with: favorite.right)
    }

    /// Saves the tabs of both panels under a name (one of the same name is replaced).
    @objc func saveFavoriteTabs(_ sender: Any?) {
        guard let window = view.window else { return }
        Prompt.text(String(localized: "Save the tabs"), message: String(localized: "The tabs of both panels, saved as:"),
                    initial: activePanel.directory.lastPathComponent, okTitle: String(localized: "Save"), in: window) {
            [weak self] text in
            guard let self else { return }
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                NSSound.beep()
                return
            }
            var favorites = FavoriteTabs.saved
            let favorite = FavoriteTabs(name: name, left: leftPanel.tabState, right: rightPanel.tabState)
            if let index = favorites.firstIndex(where: { $0.name == name }) {
                favorites[index] = favorite
            } else {
                favorites.append(favorite)
            }
            FavoriteTabs.saved = favorites
        }
    }

    @objc func removeFavoriteTabs(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        FavoriteTabs.saved.removeAll { $0.name == name }
    }

    /// Alt+Shift+F9: reads the selected archives through (or the one shown), so
    /// libarchive checks their contents, and tells which are damaged.
    @objc(cm_TestArchive:)
    func testArchives(_ sender: Any?) {
        let source = activePanel
        let archives = source.archive.map { [$0.url] }
            ?? source.selectedItems.filter { !$0.isDirectory && ArchiveReader.isArchive($0.name) }.map(\.url)
        guard !archives.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        Task {
            let entries = await Self.entries(of: archives)
            guard let passwords = await passwords(for: archives.map { ($0, entries[$0] ?? []) }) else { return }
            let total = entries.values.joined().reduce(Int64(0)) { $0 + $1.size }
            let failures = OSAllocatedUnfairLock(initialState: [String]())
            let controller = TransferController(title: String(localized: "Testing archives"),
                                                failureTitle: String(localized: "Cannot test archives"), window: window)
            let tested = await controller.run(source: archives[0].path, target: "") { progress, _ in
                progress.update { $0.totalBytes = total }
                for archive in archives {
                    do {
                        try await ArchiveReader.test(archive, password: passwords[archive], progress: progress)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if (error as? ArchiveError)?.kind == .wrongPassword {
                            await ArchivePasswords.forget(archive)
                        }
                        let line = "\u{201C}\(archive.lastPathComponent)\u{201D}: \(error.localizedDescription)"
                        failures.withLock { $0.append(line) }
                    }
                }
                return archives
            }
            guard !tested.isEmpty else { return }
            let failed = failures.withLock { $0 }
            if failed.isEmpty {
                Prompt.info(String(localized: "No errors found"), message: archives.count == 1
                    ? String(localized: "\u{201C}\(archives[0].lastPathComponent)\u{201D} was read through: its contents are intact.")
                    : String(localized: "\(archives.count) archives were read through: their contents are intact."), in: window)
            } else {
                let intact = archives.count - failed.count
                Prompt.info(String(localized: "Errors found"), message: failed.joined(separator: "\n")
                    + (intact > 0 ? "\n\n" + String(localized: "The other archives (\(intact)) are intact.") : ""), in: window)
            }
        }
    }

    /// The entries of each archive (an archive that cannot be read has none).
    @concurrent
    private nonisolated static func entries(of archives: [URL]) async -> [URL: [ArchiveEntry]] {
        Dictionary(uniqueKeysWithValues: archives.map { ($0, (try? ArchiveReader.entries(of: $0)) ?? []) })
    }

    /// Alt+F9: unpacks the selected archives, by default into the other panel.
    @objc(cm_UnpackFiles:)
    func unpackFiles(_ sender: Any?) {
        let source = activePanel
        let archives = source.archive == nil
            ? source.selectedItems.filter { !$0.isDirectory && ArchiveReader.isArchive($0.name) }
            : []
        guard !archives.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        let what = archives.count == 1 ? String(localized: "\u{201C}\(archives[0].name)\u{201D}")
            : String(localized: "\(archives.count) archives")
        Prompt.text(String(localized: "Unpack"), message: String(localized: "Unpack \(what) to:"),
                    initial: Self.folderText(inactivePanel.directory),
                    option: String(localized: "Unpack each archive to a separate folder"),
                    optionIsOn: archives.count > 1, okTitle: String(localized: "Unpack"),
                    in: window) { [weak self] text, separateFolders in
            guard let self, !text.isEmpty else { return }
            let destination = Self.resolveFolder(text, base: source.directory)
            let jobs = archives.map { archive in
                let folder = separateFolders
                    ? destination.appending(path: ArchiveReader.baseName(of: archive.name)) : destination
                return (url: archive.url, paths: [String](), base: "", destination: folder)
            }
            // Unpacking replaces existing files: ask first, as for the other operations.
            Task {
                let (existing, total, entries) = await Self.existingEntries(jobs.map { ($0.url, $0.destination) })
                let unpack: () -> Void = {
                    Task {
                        guard let passwords = await self.passwords(for: jobs.map { ($0.url, entries[$0.url] ?? []) }) else {
                            return
                        }
                        self.unpack(jobs.map { ($0.url, $0.paths, $0.base, $0.destination, passwords[$0.url]) }, total: total)
                    }
                }
                guard !existing.isEmpty else {
                    unpack()
                    return
                }
                let what = existing.count == 1 ? String(localized: "\u{201C}\(existing[0])\u{201D}")
                    : String(localized: "\(existing.count) files/folders")
                Prompt.confirm(String(localized: "\(what) already exists. Replace?"),
                               okTitle: String(localized: "Overwrite"), in: window) {
                    unpack()
                }
            }
        }
    }

    /// Top-level entries of the archives that already exist in their destinations,
    /// the total size (so the archives are not read once more for the progress) and
    /// the entries of each archive.
    @concurrent
    private nonisolated static func existingEntries(_ archives: [(url: URL, destination: URL)]) async
        -> (existing: [String], total: Int64, entries: [URL: [ArchiveEntry]]) {
        var existing: [String] = []
        var total: Int64 = 0
        var all: [URL: [ArchiveEntry]] = [:]
        for (url, destination) in archives {
            let entries = (try? ArchiveReader.entries(of: url)) ?? []
            all[url] = entries
            total += entries.reduce(Int64(0)) { $0 + $1.size }
            let names = Set(entries.compactMap {
                $0.path.split(separator: "/").first.map(String.init)
            })
            existing += names.sorted().filter {
                FileManager.default.fileExists(atPath: destination.appending(path: $0).path)
            }
        }
        return (existing, total, all)
    }

    /// The passwords of the encrypted archives among `archives`, asked one after
    /// another; nil when the user cancels or an archive cannot be decrypted (said so).
    private func passwords(for archives: [(url: URL, entries: [ArchiveEntry])]) async -> [URL: String]? {
        var passwords: [URL: String] = [:]
        for (url, entries) in archives {
            do {
                passwords[url] = try await ArchivePasswords.password(for: url, entries: entries, in: view.window)
            } catch is CancellationError {
                return nil
            } catch {
                Prompt.error(String(localized: "Cannot unpack \u{201C}\(url.lastPathComponent)\u{201D}"), error, in: view.window)
                return nil
            }
        }
        return passwords
    }

    /// Alt+F5: packs the selection into a new archive; the suffix picks the format.
    @objc(cm_PackFiles:)
    func packFiles(_ sender: Any?) {
        let source = activePanel
        let items = source.selectedItems
        guard source.archive == nil, !items.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        let name = items.count == 1 ? (items[0].isFolder ? items[0].name : items[0].baseName)
            : source.directory.lastPathComponent
        let folder = inactivePanel.archive == nil ? inactivePanel.directory : source.directory
        let initial = folder.appending(path: name + ".zip").path
        let selection = NSRange(location: (initial as NSString).length - (name as NSString).length - 4,
                                length: (name as NSString).length)
        let what = items.count == 1 ? String(localized: "\u{201C}\(items[0].name)\u{201D}")
            : String(localized: "\(items.count) files/folders")
        PackDialog.show(title: String(localized: "Pack files"),
                        message: String(localized: "Pack \(what) to archive (.zip, .tar.gz, .tar.bz2, .tar.xz, .7z):"),
                        initial: initial, selection: selection, itemCount: items.count, in: window) { [weak self] choice in
            guard let self else { return }
            var path = (choice.path as NSString).expandingTildeInPath
            if !path.hasPrefix("/") { path = source.directory.appending(path: path).path }
            let archive = URL(filePath: path).standardizedFileURL
            let folder = archive.deletingLastPathComponent()
            // One archive per item: named after it (the whole name when two would clash).
            let suffix = choice.separately ? ArchiveWriter.suffix(of: archive.lastPathComponent) : nil
            let bases = items.map { $0.isFolder ? $0.name : $0.baseName }
            let jobs: [(names: [String], archive: URL)] = suffix.map { suffix in
                items.indices.map { index in
                    let base = bases.filter { $0 == bases[index] }.count > 1 ? items[index].name : bases[index]
                    return ([items[index].name], folder.appending(path: base + suffix))
                }
            } ?? [(items.map(\.name), archive)]
            let directory = source.directory
            // A folder packed into an archive inside it would take in the archive being written.
            let inside = items.first { item in
                jobs.contains { $0.archive.path.hasPrefix(item.url.standardizedFileURL.path + "/") }
            }
            if let inside {
                Prompt.info(String(localized: "Cannot pack \u{201C}\(inside.name)\u{201D}"),
                            message: String(localized: "The archive cannot be put inside a folder being packed."), in: window)
                return
            }
            confirmOverwriting(jobs.map(\.archive.lastPathComponent), in: folder) {
                Task {
                    let controller = TransferController(title: String(localized: "Packing"),
                                                        failureTitle: String(localized: "Packing failed"), window: window)
                    _ = await controller.run(source: directory.path, target: archive.path) { progress, _ in
                        for job in jobs {
                            // The old archive is replaced only once the new one is complete.
                            try await ArchiveWriter.pack(job.names, in: directory, to: job.archive,
                                                         compression: choice.compression, password: choice.password,
                                                         encryption: choice.encryption, progress: progress)
                            guard choice.moves else { continue }
                            // The files go only once the archive reads back whole.
                            try await ArchiveReader.test(job.archive, password: choice.password, progress: TransferProgress())
                            try await FileOperations.deletePermanently(job.names.map { directory.appending(path: $0) })
                        }
                        return jobs.map(\.archive)
                    }
                    self.leftPanel.reread()
                    self.rightPanel.reread()
                }
            }
        }
    }

    private func unpack(_ archives: [(url: URL, paths: [String], base: String, destination: URL, password: String?)],
                        total: Int64?) {
        guard let window = view.window, let destination = archives.first?.destination else { return }
        Task {
            let controller = TransferController(title: String(localized: "Unpacking"),
                                                failureTitle: String(localized: "Unpacking failed"), window: window)
            _ = await controller.run(source: archives.first?.url.path ?? "", target: destination.path) { progress, _ in
                let size = try total ?? archives.reduce(Int64(0)) { sum, archive in
                    try sum + ArchiveReader.entries(of: archive.url).reduce(Int64(0)) { $0 + $1.size }
                }
                progress.update { $0.totalBytes = size }
                for archive in archives {
                    try FileManager.default.createDirectory(at: archive.destination, withIntermediateDirectories: true)
                    do {
                        try await ArchiveReader.extract(archive.url, paths: archive.paths, base: archive.base,
                                                        to: archive.destination, password: archive.password, progress: progress)
                    } catch let error as ArchiveError where error.kind == .wrongPassword {
                        await ArchivePasswords.forget(archive.url)
                        throw error
                    }
                }
                return archives.map(\.url)
            }
            leftPanel.reread()
            rightPanel.reread()
        }
    }

    /// Asks once before replacing existing items, then runs `action`.
    private func confirmOverwriting(_ names: [String], in folder: URL, then action: @escaping () -> Void) {
        let existing = names.filter { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
        guard !existing.isEmpty, let window = view.window else {
            action()
            return
        }
        let what = existing.count == 1 ? String(localized: "\u{201C}\(existing[0])\u{201D}")
            : String(localized: "\(existing.count) files/folders")
        Prompt.confirm(String(localized: "\(what) already exists. Replace?"), okTitle: String(localized: "Overwrite"),
                       in: window, completion: action)
    }

    private static func folderText(_ url: URL) -> String {
        url.path.hasSuffix("/") ? url.path : url.path + "/"
    }

    /// A folder typed in a dialog; relative paths are relative to `base`.
    private static func resolveFolder(_ text: String, base: URL) -> URL {
        let path = (text as NSString).expandingTildeInPath
        return (path.hasPrefix("/") ? URL(filePath: path) : base.appending(path: path)).standardizedFileURL
    }

    /// Interprets the target typed in the copy/move dialog: an existing folder or a
    /// path ending in "/" receives the items; otherwise a single item gets that name.
    /// A last part with wildcards ("*.*", "*.bak") is a mask for the new names.
    /// Relative paths are relative to the source folder.
    static func resolveTarget(_ text: String, itemCount: Int, base: URL, source: URL? = nil)
        -> (destination: URL, newName: String?, renameMask: RenameMask?) {
        var text = text
        var mask: RenameMask?
        if let last = text.split(separator: "/", omittingEmptySubsequences: false).last,
           last.contains(where: { $0 == "*" || $0 == "?" }) {
            mask = RenameMask(String(last))
            text = String(text.dropLast(last.count))
            if text.isEmpty { text = "./" }
        }
        let (destination, newName) = resolveTargetPath(text, itemCount: itemCount, base: base, source: source)
        return (destination, newName, mask)
    }

    private static func resolveTargetPath(_ text: String, itemCount: Int, base: URL,
                                          source: URL?) -> (destination: URL, newName: String?) {
        var path = (text as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = base.appending(path: path).path
        }
        let url = URL(filePath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // The single item itself under another letter case ("Folder" → "folder"):
        // a rename, not a move into it.
        if itemCount == 1, !text.hasSuffix("/"), let source, isSameEntry(url, source) {
            return (url.deletingLastPathComponent(), url.lastPathComponent)
        }
        if text.hasSuffix("/") || (exists && isDirectory.boolValue) || itemCount > 1 {
            return (url, nil)
        }
        return (url.deletingLastPathComponent(), url.lastPathComponent)
    }

    private static func isSameEntry(_ a: URL, _ b: URL) -> Bool {
        var first = stat()
        var second = stat()
        return lstat(a.path, &first) == 0 && lstat(b.path, &second) == 0
            && first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// Ctrl+Left/Right (or Ctrl+Shift+Left/Right): shows the folder or archive under
    /// the cursor in the given panel, or the folder of the file under the cursor with
    /// that file selected; pressed towards the active panel itself, it shows the other
    /// panel's folder there.
    @objc(cm_TransferLeft:)
    func transferLeft(_ sender: Any?) {
        transfer(to: leftPanel)
    }

    @objc(cm_TransferRight:)
    func transferRight(_ sender: Any?) {
        transfer(to: rightPanel)
    }

    private func transfer(to target: FilePanelController) {
        let towardsItself = target === activePanel
        target.show(locationOf: towardsItself ? inactivePanel : activePanel, underCursor: !towardsItself)
    }

    /// Alt+F1 / Alt+F2: opens the volume list of the left or right panel.
    @objc(cm_LeftOpenDrives:)
    func leftOpenDrives(_ sender: Any?) {
        leftPanel.focus()
        leftPanel.panelView.volumeButton.performClick(nil)
    }

    @objc(cm_RightOpenDrives:)
    func rightOpenDrives(_ sender: Any?) {
        rightPanel.focus()
        rightPanel.panelView.volumeButton.performClick(nil)
    }

    /// Alt+F7: find files; the chosen result is shown in the active panel.
    @objc(cm_SearchFor:)
    func searchFor(_ sender: Any?) {
        FindFilesWindowController.show(searchingIn: activePanel.directory, goTo: { [weak self] found in
            guard let self else { return }
            if let entry = found.entry {
                activePanel.openArchive(found.url, folder: (entry as NSString).deletingLastPathComponent,
                                        selecting: (entry as NSString).lastPathComponent)
            } else {
                activePanel.load(found.url.deletingLastPathComponent(), selecting: found.url.lastPathComponent)
            }
            view.window?.makeKeyAndOrderFront(nil)
            activePanel.focus()
        }, feed: { [weak self] results, root, title in
            guard let self else { return }
            activePanel.showSearchResults(results, root: root, title: title)
            view.window?.makeKeyAndOrderFront(nil)
            activePanel.focus()
        })
    }

    /// Shift+F2: marks the files that are missing from, or newer than, the other panel.
    @objc(cm_CompareDirs:)
    func compareDirs(_ sender: Any?) {
        func files(_ panel: FilePanelController) -> [String: FileItem] {
            Dictionary(panel.listView.items.filter { !$0.isParent && !$0.isFolder }.map { ($0.name, $0) },
                       uniquingKeysWith: { first, _ in first })
        }
        let left = files(leftPanel)
        let right = files(rightPanel)
        var markLeft = Set<String>()
        var markRight = Set<String>()
        for (name, file) in left {
            guard let other = right[name] else {
                markLeft.insert(name)
                continue
            }
            let difference = file.modified.timeIntervalSince(other.modified)
            if difference > DirectoryComparison.dateTolerance {
                markLeft.insert(name)
            } else if difference < -DirectoryComparison.dateTolerance {
                markRight.insert(name)
            } else if file.size != other.size {
                markLeft.insert(name)
                markRight.insert(name)
            }
        }
        markRight.formUnion(right.keys.filter { left[$0] == nil })
        leftPanel.listView.setMarked(markLeft)
        rightPanel.listView.setMarked(markRight)
        if markLeft.isEmpty && markRight.isEmpty {
            Prompt.info(String(localized: "The panels contain the same files."), message: "", in: view.window)
        }
    }

    /// Compares two files: the two marked in the active panel, or the files under
    /// the cursors of both panels. Different files open in the compare window.
    @objc(cm_CompareFilesByContent:)
    func compareFilesByContent(_ sender: Any?) {
        let marked = activePanel.selectedItems.filter { !$0.isFolder }
        let pair: [FileItem]
        if marked.count == 2 {
            pair = marked
        } else if let left = leftPanel.listView.currentItem, let right = rightPanel.listView.currentItem,
                  !left.isFolder, !right.isFolder, !left.isParent, !right.isParent {
            pair = [left, right]
        } else {
            pair = []
        }
        guard pair.count == 2, leftPanel.archive == nil, rightPanel.archive == nil,
              leftPanel.remote == nil, rightPanel.remote == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        let (a, b) = (pair[0].url, pair[1].url)
        Task {
            guard await Self.firstDifference(a, b) != nil else {
                Prompt.info(String(localized: "The files are identical."), message: "\(a.path)\n\(b.path)", in: window)
                return
            }
            CompareWindowController.show(a, b)
        }
    }

    @concurrent
    private nonisolated static func firstDifference(_ a: URL, _ b: URL) async -> Int64? {
        DirectoryComparison.firstDifference(a, b)
    }

    /// Ctrl+Shift+F5: creates a symbolic link to the entry under the cursor,
    /// by default in the other panel.
    @objc(cm_CreateSymlink:)
    func createSymlink(_ sender: Any?) {
        guard let item = activePanel.listView.currentItem, !item.isParent, activePanel.archive == nil,
              let window = view.window else {
            NSSound.beep()
            return
        }
        let folder = inactivePanel.archive == nil ? inactivePanel.directory : activePanel.directory
        let initial = folder.appending(path: item.name).path
        Prompt.text(String(localized: "Create Symbolic Link"),
                    message: String(localized: "Link to \u{201C}\(item.name)\u{201D} to create:"),
                    initial: initial, okTitle: String(localized: "Create"), in: window) { [weak self] path in
            guard let self, !path.isEmpty else { return }
            let link = URL(filePath: (path as NSString).expandingTildeInPath)
            do {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item.url)
                leftPanel.reread()
                rightPanel.reread()
            } catch {
                Prompt.error(String(localized: "Cannot create link"), error, in: window)
            }
        }
    }

    /// The piece sizes offered when splitting (any other can be typed).
    private static let pieceSizes = ["10 MB", "100 MB", "650 MB", "700 MB", "1 GB", "2 GB", "4095 MB", "4.7 GB"]

    /// "650 MB", "1.5 GB", "100000": bytes (no unit: megabytes).
    private static func bytes(in text: String) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: ",", with: ".")
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let number = parts.first.flatMap({ Double($0) }), number > 0 else { return nil }
        let unit: Double = switch parts.count > 1 ? String(parts[1]) : "MB" {
        case "B": 1
        case "KB", "K": 1024
        case "MB", "M": 1024 * 1024
        case "GB", "G": 1024 * 1024 * 1024
        default: 0
        }
        return unit > 0 ? Int64(number * unit) : nil
    }

    /// Files → Split File… (cm_FileSpliter): the file under the cursor cut into
    /// pieces of a size chosen (`name.001`… and `name.crc`), by default in the
    /// other panel.
    @objc(cm_FileSpliter:)
    func fileSpliter(_ sender: Any?) {
        guard let item = activePanel.listView.currentItem, !item.isParent, !item.isDirectory,
              activePanel.archive == nil, activePanel.remote == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        let folderField = NSTextField(string: Self.folderText(inactivePanel.archive == nil && inactivePanel.remote == nil
            ? inactivePanel.directory : activePanel.directory))
        let sizeBox = NSComboBox()
        sizeBox.addItems(withObjectValues: Self.pieceSizes)
        sizeBox.stringValue = AppDefaults.store.string(forKey: "SplitPieceSize") ?? "100 MB"
        folderField.identifier = NSUserInterfaceItemIdentifier("splitFolder")
        sizeBox.identifier = NSUserInterfaceItemIdentifier("splitSize")
        folderField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let grid = NSGridView(views: [[NSTextField(labelWithString: String(localized: "Into:")), folderField],
                                      [NSTextField(labelWithString: String(localized: "Piece size:")), sizeBox]])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let alert = NSAlert()
        alert.messageText = String(localized: "Split File")
        alert.informativeText = String(localized: "Cut \u{201C}\(item.name)\u{201D} into pieces:")
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Split"))
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let size = Self.bytes(in: sizeBox.stringValue) else {
                Prompt.info(String(localized: "Cannot split \u{201C}\(item.name)\u{201D}"),
                            message: String(localized: "The piece size is not understood: write it as 650 MB or 1.5 GB."),
                            in: window)
                return
            }
            AppDefaults.store.set(sizeBox.stringValue, forKey: "SplitPieceSize")
            let folder = Self.resolveFolder(folderField.stringValue, base: activePanel.directory)
            Task {
                let controller = TransferController(title: String(localized: "Splitting"),
                                                    failureTitle: String(localized: "Splitting failed"), window: window)
                _ = await controller.run(source: item.url.path, target: folder.path) { progress, _ in
                    try await FileSplitter.split(item.url, pieceSize: size, into: folder, progress: progress)
                }
                self.leftPanel.reread()
                self.rightPanel.reread()
            }
        }
    }

    /// Files → Encode File (cm_UUEncode): the file under the cursor as text for
    /// mail — MIME, UUE or XXE — by default in the other panel.
    @objc(cm_UUEncode:)
    func uuEncode(_ sender: Any?) {
        guard let item = activePanel.listView.currentItem, !item.isParent, !item.isDirectory,
              activePanel.archive == nil, activePanel.remote == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        let folderField = NSTextField(string: Self.folderText(inactivePanel.archive == nil && inactivePanel.remote == nil
            ? inactivePanel.directory : activePanel.directory))
        folderField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let formatPopup = NSPopUpButton()
        formatPopup.addItems(withTitles: MailEncoding.allCases.map(\.title))
        formatPopup.selectItem(at: AppDefaults.store.integer(forKey: "EncodeFormat"))
        folderField.identifier = NSUserInterfaceItemIdentifier("encodeFolder")
        formatPopup.identifier = NSUserInterfaceItemIdentifier("encodeFormat")
        let grid = NSGridView(views: [[NSTextField(labelWithString: String(localized: "Into:")), folderField],
                                      [NSTextField(labelWithString: String(localized: "Format:")), formatPopup]])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let alert = NSAlert()
        alert.messageText = String(localized: "Encode File")
        alert.informativeText = String(localized: "\u{201C}\(item.name)\u{201D} as text for mail:")
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Encode"))
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let format = MailEncoding(rawValue: formatPopup.indexOfSelectedItem) ?? .mime
            AppDefaults.store.set(format.rawValue, forKey: "EncodeFormat")
            let folder = Self.resolveFolder(folderField.stringValue, base: activePanel.directory)
            let target = folder.appending(path: (item.name as NSString).deletingPathExtension + "." + format.fileExtension)
            confirmOverwriting([target.lastPathComponent], in: folder) { [self] in
                do {
                    let data = try Data(contentsOf: item.url)
                    try format.encode(data, name: item.name).write(to: target, atomically: true, encoding: .utf8)
                } catch {
                    Prompt.error(String(localized: "Cannot encode \u{201C}\(item.name)\u{201D}"), error, in: window)
                }
                leftPanel.reread()
                rightPanel.reread()
            }
        }
    }

    /// Files → Decode File (cm_UUDecode): the file a MIME, UUE or XXE text holds,
    /// under the name it gives, by default in the other panel.
    @objc(cm_UUDecode:)
    func uuDecode(_ sender: Any?) {
        guard let item = activePanel.listView.currentItem, !item.isParent, !item.isDirectory,
              activePanel.archive == nil, activePanel.remote == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        guard let text = (try? String(contentsOf: item.url, encoding: .utf8))
                ?? (try? String(contentsOf: item.url, encoding: .isoLatin1)),
              let decoded = MailEncoding.decode(text) else {
            Prompt.info(String(localized: "Cannot decode \u{201C}\(item.name)\u{201D}"),
                        message: String(localized: "It holds no MIME (Base64), UUE or XXE encoded file."), in: window)
            return
        }
        let name = decoded.name.flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 }
            ?? (item.name as NSString).deletingPathExtension
        Prompt.text(String(localized: "Decode File"), message: String(localized: "Put \u{201C}\(name)\u{201D} in:"),
                    initial: Self.folderText(inactivePanel.archive == nil && inactivePanel.remote == nil
                        ? inactivePanel.directory : activePanel.directory),
                    okTitle: String(localized: "Decode"), in: window) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let folder = Self.resolveFolder(text, base: activePanel.directory)
            confirmOverwriting([name], in: folder) { [self] in
                do {
                    try decoded.data.write(to: folder.appending(path: name), options: .atomic)
                } catch {
                    Prompt.error(String(localized: "Cannot decode \u{201C}\(item.name)\u{201D}"), error, in: window)
                }
                leftPanel.reread()
                rightPanel.reread()
            }
        }
    }

    /// Files → Combine Files… (cm_FileCombine): the pieces of the one under the
    /// cursor (`name.001`, or `name.crc`) put together, by default in the other panel.
    @objc(cm_FileCombine:)
    func fileCombine(_ sender: Any?) {
        guard let item = activePanel.listView.currentItem, !item.isParent, !item.isDirectory,
              activePanel.archive == nil, activePanel.remote == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        let first = item.url.pathExtension.lowercased() == "crc"
            ? item.url.deletingPathExtension().appendingPathExtension("001") : item.url
        guard FileSplitter.baseName(of: first) != nil, FileManager.default.fileExists(atPath: first.path) else {
            Prompt.info(String(localized: "Cannot combine \u{201C}\(item.name)\u{201D}"),
                        message: String(localized: "Choose the first piece (a name ending in .001) or the .crc file."),
                        in: window)
            return
        }
        Prompt.text(String(localized: "Combine Files"),
                    message: String(localized: "Put the pieces of \u{201C}\(first.deletingPathExtension().lastPathComponent)\u{201D} together in:"),
                    initial: Self.folderText(inactivePanel.archive == nil && inactivePanel.remote == nil
                        ? inactivePanel.directory : activePanel.directory),
                    okTitle: String(localized: "Combine"), in: window) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let folder = Self.resolveFolder(text, base: activePanel.directory)
            confirmOverwriting([FileSplitter.combinedName(of: first) ?? ""], in: folder) { [self] in
            Task {
                let controller = TransferController(title: String(localized: "Combining"),
                                                    failureTitle: String(localized: "Combining failed"), window: window)
                _ = await controller.run(source: first.path, target: folder.path) { progress, _ in
                    [try await FileSplitter.combine(first, into: folder, progress: progress)]
                }
                self.leftPanel.reread()
                self.rightPanel.reread()
            }
            }
        }
    }

    /// A hard link to the file under the cursor: another name of the same file (on
    /// the same volume; folders cannot have them).
    @objc(cm_CreateHardLink:)
    func createHardLink(_ sender: Any?) {
        guard let item = activePanel.listView.currentItem, !item.isParent, !item.isDirectory, !item.isSymlink,
              activePanel.archive == nil, activePanel.remote == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        let folder = inactivePanel.archive == nil && inactivePanel.remote == nil ? inactivePanel.directory : activePanel.directory
        let initial = folder.appending(path: item.name).path
        Prompt.text(String(localized: "Create Hard Link"),
                    message: String(localized: "Another name of \u{201C}\(item.name)\u{201D} (on the same volume):"),
                    initial: initial, okTitle: String(localized: "Create"), in: window) { [weak self] path in
            guard let self, !path.isEmpty else { return }
            let link = URL(filePath: (path as NSString).expandingTildeInPath)
            do {
                try FileManager.default.linkItem(at: item.url, to: link)
                leftPanel.reread()
                rightPanel.reread()
            } catch {
                Prompt.error(String(localized: "Cannot create link"), error, in: window)
            }
        }
    }

    /// Opens the "Synchronize directories" window for the two panels' folders.
    @objc(cm_SyncDirs:)
    func syncDirs(_ sender: Any?) {
        SyncWindowController.show(left: leftPanel.directory, right: rightPanel.directory) { [weak self] in
            self?.leftPanel.reread()
            self?.rightPanel.reread()
        }
    }

    /// Runs a Start menu command (from the menu or the button bar).
    @objc func runUserCommand(_ sender: Any?) {
        let id: String?
        if let item = sender as? NSMenuItem {
            id = item.representedObject as? String
        } else if let item = sender as? NSToolbarItem {
            id = ButtonBar.userCommandID(from: item.itemIdentifier)
        } else {
            id = nil
        }
        guard let command = id.flatMap(UserCommands.command(withID:)), !command.command.isEmpty else {
            NSSound.beep()
            return
        }
        let context = UserCommand.Context(
            sourcePath: activePanel.directory.path,
            currentName: activePanel.listView.currentItem.flatMap { $0.isParent ? nil : $0.name },
            selectedNames: activePanel.selectedItems.map(\.name),
            targetPath: inactivePanel.directory.path,
            targetName: inactivePanel.listView.currentItem.flatMap { $0.isParent ? nil : $0.name }
        )
        let line = command.expanded(with: context)
        if command.runsInTerminal {
            ShellRunner.runInTerminal(line, in: activePanel.directory)
        } else {
            ShellRunner.run(line, in: activePanel.directory, window: view.window)
        }
    }

    private static let recentServersKey = "RecentServers"

    /// The last ten servers connected to with ⌘K, the latest first (without passwords).
    private static var recentServers: [String] {
        get { AppDefaults.store.stringArray(forKey: recentServersKey) ?? [] }
        set { AppDefaults.store.set(Array(newValue.prefix(10)), forKey: recentServersKey) }
    }

    /// ⌘K: connects to a server (SFTP, FTP) or mounts a network share, and shows it in
    /// the active panel. The recent servers are listed under the address.
    @objc func connectToServer(_ sender: Any?) {
        guard let window = view.window else { return }
        let key = "LastServerAddress"
        ServerAddressSheet.show(String(localized: "Connect to Server"),
                                message: String(localized: "Server address (sftp://, ftp://, ftps://, smb://, afp://, nfs://, https:// for WebDAV):"),
                                initial: AppDefaults.store.string(forKey: key) ?? "smb://",
                                recent: Self.recentServers,
                                okTitle: String(localized: "Connect"), in: window,
                                onRemove: { address in Self.recentServers.removeAll { $0 == address } }) { [weak self] address in
            self?.connect(to: address)
        }
    }

    /// Connects to a server address (typed in Connect to Server or the path bar).
    private func connect(to address: String) {
        guard let window = view.window,
              let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            NSSound.beep()
            return
        }
        // Remembered for next time, but never with a password typed into the address.
        var remembered = URLComponents(url: url, resolvingAgainstBaseURL: false)
        remembered?.password = nil
        let shown = remembered?.string ?? address
        AppDefaults.store.set(shown, forKey: "LastServerAddress")
        if let port = url.port, !(1...65535).contains(port) {
            Prompt.info(String(localized: "Cannot connect to \u{201C}\(shown)\u{201D}"),
                        message: String(localized: "The port must be a number from 1 to 65535."), in: window)
            return
        }
        // Only addresses that worked join the recent list, so typos do not.
        let connected = { Self.recentServers = [shown] + Self.recentServers.filter { $0 != shown } }
        if connectRemote(url, password: nil, onConnected: connected) {
            return
        }
        mount(url, named: shown, in: window, onMounted: connected)
    }

    /// Mounts a network share, showing that it connects (with Cancel). A server that
    /// does not answer at all is reported at once instead of after the mount's long wait.
    private func mount(_ url: URL, named address: String, in window: NSWindow, onMounted: @escaping () -> Void) {
        let mounting = TaskHolder()
        let closeProgress = Prompt.progress(String(localized: "Connecting to \u{201C}\(address)\u{201D}…"), in: window) {
            mounting.task?.cancel()
        }
        mounting.task = Task { [weak self] in
            do {
                let answers = await NetworkConnection.serverAnswers(url)
                try Task.checkCancellation()
                guard answers else {
                    throw RemoteError(String(localized: "The server does not answer. Check the address and the network."))
                }
                let mountPoint = try await NetworkConnection.mount(url)
                closeProgress()
                onMounted()
                self?.activePanel.load(mountPoint)
            } catch is CancellationError {
                closeProgress()
            } catch {
                closeProgress()
                // macOS has shown its own message for these (NetAuthAgent): not twice.
                if let posix = error as? POSIXError, NetworkConnection.errorsShownBySystem.contains(posix.code) { return }
                Prompt.error(String(localized: "Cannot connect to \u{201C}\(address)\u{201D}"), error, in: window)
            }
        }
    }

    /// Net → Connections (Total Commander's Ctrl+F): the saved servers.
    @objc(cm_FtpConnect:)
    func ftpConnect(_ sender: Any?) {
        ConnectionsWindowController.shared.show { [weak self] url, password in
            guard let self else { return }
            view.window?.makeKeyAndOrderFront(nil)
            if !connectRemote(url, password: password) {
                NSSound.beep()
            }
        }
    }

    /// Opens an SFTP or FTP server in the active panel. Returns false for other addresses.
    private func connectRemote(_ url: URL, password: String?, onConnected: (() -> Void)? = nil) -> Bool {
        if let fileSystem = SFTPFileSystem(url: url, password: password) {
            activePanel.openRemote(fileSystem, onConnected: onConnected)
            return true
        }
        guard ["ftp", "ftps", "ftpes"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if let password, let fileSystem = FTPFileSystem(url: url, password: password) {
            activePanel.openRemote(fileSystem, onConnected: onConnected)
        } else {
            connectFTP(url, onConnected: onConnected)
        }
        return true
    }

    /// Opens an FTP server in the active panel, asking for the password if needed.
    private func connectFTP(_ url: URL, onConnected: (() -> Void)?) {
        guard let window = view.window else { return }
        if FTPFileSystem.needsPassword(url) {
            Prompt.password(String(localized: "Connect to Server"),
                            message: String(localized: "Password for \(url.user(percentEncoded: false) ?? "")@\(url.host() ?? ""):"),
                            in: window) { [weak self] password in
                if let fileSystem = FTPFileSystem(url: url, password: password) {
                    self?.activePanel.openRemote(fileSystem, onConnected: onConnected)
                }
            }
        } else if let fileSystem = FTPFileSystem(url: url, password: nil) {
            activePanel.openRemote(fileSystem, onConnected: onConnected)
        }
    }

    /// Left = Right: shows the right panel's folder in the left panel.
    @objc(cm_LeftEqualRight:)
    func leftEqualRight(_ sender: Any?) {
        leftPanel.load(rightPanel.directory)
    }

    /// Right = Left: shows the left panel's folder in the right panel.
    @objc(cm_RightEqualLeft:)
    func rightEqualLeft(_ sender: Any?) {
        rightPanel.load(leftPanel.directory)
    }

    /// ⌘E: ejects the (removable or network) volume shown in the active panel.
    @objc func ejectVolume(_ sender: Any?) {
        guard let volume = ejectableVolume else {
            NSSound.beep()
            return
        }
        eject(volume)
    }

    private func eject(_ volume: URL) {
        // Leave the volume in both panels first, so nothing keeps it busy.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = volume.path.hasSuffix("/") ? volume.path : volume.path + "/"
        for panel in [leftPanel, rightPanel] where panel.directory.path == volume.path || panel.directory.path.hasPrefix(root) {
            panel.leaveLocalFolder(for: home)
        }
        let window = view.window
        Task {
            if let error = await Self.eject(volume) {
                Prompt.error(String(localized: "Cannot eject \u{201C}\(volume.lastPathComponent)\u{201D}"), error,
                             in: window)
            }
        }
    }

    /// The volume of the active panel's folder, if it can be ejected.
    private var ejectableVolume: URL? {
        guard let volume = Volume.containing(activePanel.directory, in: Volume.mounted())?.url else { return nil }
        return Volume.isEjectable(volume) ? volume : nil
    }

    @concurrent
    private nonisolated static func eject(_ volume: URL) async -> Error? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            return nil
        } catch {
            return error
        }
    }

    /// Opens Terminal in the active panel's folder.
    @objc(cm_ExecuteDOS:)
    func executeDOS(_ sender: Any?) {
        ShellRunner.openTerminal(in: activePanel.directory)
    }

    /// Ctrl+Q: turns the other panel into a preview of the entry under the cursor.
    @objc(cm_SrcQuickview:)
    func srcQuickView(_ sender: Any?) {
        if quickView == nil {
            openQuickView()
        } else {
            closeQuickView()
        }
    }

    /// Puts `newView` where `oldView` is in the split view, keeping the divider.
    private func replaceInSplitView(_ oldView: NSView, with newView: NSView) {
        guard let index = splitView.arrangedSubviews.firstIndex(of: oldView) else { return }
        let first = splitView.arrangedSubviews[0].frame
        let position = splitView.isVertical ? first.width : first.height
        splitView.removeArrangedSubview(oldView)
        oldView.removeFromSuperview()
        splitView.insertArrangedSubview(newView, at: index)
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(position, ofDividerAt: 0)
    }

    private func openQuickView() {
        closeTree()
        let replaced = inactivePanel
        let panel = QuickViewPanel()
        replaceInSplitView(replaced.view, with: panel)
        quickView = panel
        quickViewReplaces = replaced
        updateQuickView()
    }

    private func closeQuickView() {
        guard let panel = quickView, let replaced = quickViewReplaces else { return }
        panel.close()
        replaceInSplitView(panel, with: replaced.view)
        quickView = nil
        quickViewReplaces = nil
    }

    /// Ctrl+F8: turns the active panel into a folder tree; the other panel
    /// follows the selected folder.
    @objc(cm_SrcTree:)
    func srcTree(_ sender: Any?) {
        if treePanel == nil {
            openTree()
        } else {
            closeTree()
        }
    }

    private func openTree() {
        closeQuickView()
        let replaced = activePanel
        let target = inactivePanel
        let tree = DirectoryTreePanel(root: URL(filePath: "/"), showsHidden: showsHidden)
        replaceInSplitView(replaced.view, with: tree)
        treePanel = tree
        treeReplaces = replaced
        tree.reveal(replaced.directory)
        tree.onSelect = { url in target.load(url) }
        tree.onSwitchPanel = { target.focus() }
        tree.onClose = { [weak self] mode in
            self?.closeTree()
            replaced.viewMode = mode
        }
        tree.focus()
    }

    /// Restores the panel, showing the folder selected in the tree.
    private func closeTree() {
        guard let tree = treePanel, let replaced = treeReplaces else { return }
        let selected = tree.selectedURL
        replaceInSplitView(tree, with: replaced.view)
        treePanel = nil
        treeReplaces = nil
        if let selected {
            replaced.load(selected)
        }
        replaced.focus()
    }

    private func updateQuickView() {
        guard let quickView else { return }
        let item = activePanel.listView.currentItem
        quickView.show(item.flatMap { $0.isParent ? nil : $0.url })
    }

    @objc(cm_SyncChangeDir:)
    func toggleSyncChangeDir(_ sender: Any?) {
        syncsDirectoryChanges.toggle()
    }

    /// Repeats a step into subfolders or up to a parent of `panel` in the other panel.
    private func followDirectoryChange(of panel: FilePanelController, from previous: URL) {
        let other = panel === leftPanel ? rightPanel : leftPanel
        guard panel.remote == nil, panel.archive == nil, other.remote == nil, other.archive == nil else { return }
        let old = previous.standardizedFileURL.pathComponents
        let new = panel.directory.standardizedFileURL.pathComponents
        var target = other.directory
        var selecting: String?
        if new.count > old.count, Array(new.prefix(old.count)) == old {
            for name in new.dropFirst(old.count) {
                target.append(path: name, directoryHint: .isDirectory)
            }
        } else if old.count > new.count, Array(old.prefix(new.count)) == new {
            for _ in new.count..<old.count {
                guard target.path != "/" else {
                    NSSound.beep()
                    return
                }
                selecting = target.lastPathComponent
                target.deleteLastPathComponent()
            }
        } else {
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        other.load(target, selecting: selecting)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == Command.switchHidSys.selector {
            menuItem.state = showsHidden ? .on : .off
        } else if menuItem.action == Command.srcQuickView.selector {
            menuItem.state = quickView == nil ? .off : .on
        } else if menuItem.action == #selector(ejectVolume(_:)) {
            return ejectableVolume != nil
        } else if menuItem.action == Command.switchIgnoreList.selector {
            menuItem.state = Settings.usesIgnoreList ? .on : .off
        } else if menuItem.action == Command.horizontalPanels.selector {
            menuItem.state = splitView.isVertical ? .off : .on
        } else if menuItem.action == Command.toggleSeparateTree1.selector {
            menuItem.state = separateTree == nil ? .off : .on
        } else if menuItem.action == Command.srcTree.selector {
            menuItem.state = treePanel == nil ? .off : .on
        } else if menuItem.action == Command.syncChangeDir.selector {
            menuItem.state = syncsDirectoryChanges ? .on : .off
        }
        return true
    }
}

extension MainViewController: FilePanelControllerDelegate {
    func filePanel(_ panel: FilePanelController, openDriveInOtherPanel url: URL) {
        (panel === leftPanel ? rightPanel : leftPanel).openDrive(url)
    }

    func filePanel(_ panel: FilePanelController, eject volume: URL) {
        eject(volume)
    }

    func filePanel(_ panel: FilePanelController, takeTab id: UUID) -> FilePanelController.Tab? {
        (panel === leftPanel ? rightPanel : leftPanel).giveTab(id)
    }

    func filePanel(_ panel: FilePanelController, openAddress address: String) {
        activate(panel)
        connect(to: address)
    }

    func filePanel(_ panel: FilePanelController, otherTabsShow server: String) -> Bool {
        panels.contains { $0.showsServer(server, excludingActiveTab: $0 === panel) }
    }

    func filePanelDidBecomeActive(_ panel: FilePanelController) {
        activate(panel)
    }

    func filePanelSwitchPanel(_ panel: FilePanelController) {
        closeQuickView()
        let other = panel === leftPanel ? rightPanel : leftPanel
        if let treePanel, other === treeReplaces {
            treePanel.focus()
        } else {
            other.focus()
        }
    }

    func filePanel(_ panel: FilePanelController, interceptKey event: NSEvent) -> Bool {
        commandLine.handlePanelKey(event, lettersStartQuickSearch: Settings.quickSearchMode == .letters)
    }

    func filePanelCursorDidMove(_ panel: FilePanelController) {
        if panel === activePanel {
            updateQuickView()
        }
    }

    func filePanelDidChangeDirectory(_ panel: FilePanelController) {
        let previous = lastDirectories.updateValue(panel.directory, forKey: ObjectIdentifier(panel))
        if syncsDirectoryChanges, panel === activePanel, let previous, previous != panel.directory {
            followDirectoryChange(of: panel, from: previous)
        }
        savePanels()
        let showTabs = leftPanel.tabs.count > 1 || rightPanel.tabs.count > 1
        leftPanel.alwaysShowsTabBar = showTabs
        rightPanel.alwaysShowsTabBar = showTabs
        if panel === activePanel {
            commandLine.view.directory = panel.directory
            separateTree?.reveal(panel.directory, quietly: true)
        }
    }
}

extension MainViewController: CommandLineControllerDelegate {
    var commandLineDirectory: URL { activePanel.directory }

    var commandLineCurrentItem: FileItem? { activePanel.listView.currentItem }

    func commandLine(_ controller: CommandLineController, changeDirectoryTo url: URL) {
        activePanel.load(url)
    }

    func commandLineDidEndEditing(_ controller: CommandLineController) {
        activePanel.focus()
    }
}

extension MainViewController: NSSplitViewDelegate {
    /// Remembers where the user put the splitter (as a share of the width).
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard didAppear, splitView.bounds.width > 0 else { return }
        AppDefaults.store.set(Double(splitView.ratio), forKey: Self.splitRatioKey)
    }
}
