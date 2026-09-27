import AppKit

/// Root view of the main window: two panels side by side,
/// the command line and the function key bar underneath.
final class MainViewController: NSViewController {
    private let leftPanel: FilePanelController
    private let rightPanel: FilePanelController
    private let splitView = PanelSplitView()
    private static let splitRatioKey = "PanelSplitRatio"
    private let commandLine = CommandLineController()
    private let functionKeyBar = FunctionKeyBar()

    private var didAppear = false
    private var commandLineHeight: NSLayoutConstraint!
    private var functionKeyBarHeight: NSLayoutConstraint!

    /// Ctrl+Q preview shown in place of `quickViewReplaces`' view.
    private var quickView: QuickViewPanel?
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
        commandLineHeight = commandLine.view.heightAnchor.constraint(equalToConstant: CommandLineView.height)
        functionKeyBarHeight = functionKeyBar.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            commandLineHeight,
            functionKeyBarHeight,
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
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
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        applyLayoutSettings()
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
        let paths = state?["tabs"] as? [String] ?? []
        let active = state?["active"] as? Int ?? 0
        var directories: [URL] = []
        var activeIndex = 0
        for (index, path) in paths.enumerated() where FileManager.default.fileExists(atPath: path) {
            if index == active { activeIndex = directories.count }
            directories.append(URL(filePath: path))
        }
        let panel = FilePanelController(tabDirectories: directories, activeTab: activeIndex)
        panel.viewMode = viewMode
        return panel
    }

    private func savePanels() {
        for (panel, key) in [(leftPanel, Self.leftPanelKey), (rightPanel, Self.rightPanelKey)] {
            let state = panel.tabState
            AppDefaults.store.set(["tabs": state.directories, "active": state.active,
                                   "view": panel.viewMode.rawValue], forKey: key)
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
        commandLine.view.directory = panel.directory
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
        if source.remote != nil || inactivePanel.remote != nil {
            askForServerTransfer(items, kind: kind, from: source, to: inactivePanel)
            return
        }
        if let target = inactivePanel.archive, source.archive == nil, ArchiveEditor.isWritable(target.url) {
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
        let what = items.count == 1 ? String(localized: "\u{201C}\(items[0].name)\u{201D}") : String(localized: "\(items.count) files/folders")
        let targetPath = inactivePanel.directory.path
        let initial = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
        Prompt.text(kind == .copy ? String(localized: "copy.title", defaultValue: "Copy") : String(localized: "Move/Rename"),
                    message: kind == .copy ? String(localized: "Copy \(what) to:") : String(localized: "Rename/move \(what) to:"),
                    initial: initial, okTitle: kind == .copy ? String(localized: "copy.button", defaultValue: "Copy")
                        : String(localized: "move.button", defaultValue: "Move"),
                    queueTitle: String(localized: "Queue (F2)"), in: window) { [weak self] text, queued in
            self?.transfer(kind, items: items, from: source, to: text, queued: queued)
        }
    }

    private func transfer(_ kind: TransferJob.Kind, items: [FileItem], from source: FilePanelController, to text: String,
                          queued: Bool = false) {
        guard let window = view.window, !text.isEmpty else { return }
        let (destination, newName) = Self.resolveTarget(text, itemCount: items.count, base: source.directory)
        let job = TransferJob(kind: kind, sources: items.map(\.url), destination: destination, newName: newName)
        let operation = { [weak self] in
            let done = await TransferController.run(job, in: window, inBackground: queued)
            let transferred = Set(done)
            source.listView.setMarked(source.listView.marked.subtracting(
                items.filter { transferred.contains($0.url) }.map(\.name)))
            self?.leftPanel.reread()
            self?.rightPanel.reread()
        }
        if queued {
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
            let total = archive.entries
                .filter { entry in paths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }
                .reduce(Int64(0)) { $0 + $1.size }
            confirmOverwriting(items.map(\.name), in: destination) {
                self.unpack([(archive.url, paths, archive.folder, destination)], total: total)
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
            unpack(archives.map { archive in
                let folder = separateFolders
                    ? destination.appending(path: ArchiveReader.baseName(of: archive.name)) : destination
                return (archive.url, [], "", folder)
            }, total: nil)
        }
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
        Prompt.text(String(localized: "Pack files"),
                    message: String(localized: "Pack \(what) to archive (.zip, .tar.gz, .tar.bz2, .tar.xz, .7z):"),
                    initial: initial, selection: selection, okTitle: String(localized: "Pack"), in: window) {
            [weak self] text in
            guard let self, !text.isEmpty else { return }
            var path = (text as NSString).expandingTildeInPath
            if !path.hasPrefix("/") { path = source.directory.appending(path: path).path }
            let archive = URL(filePath: path)
            let names = items.map(\.name)
            confirmOverwriting([archive.lastPathComponent], in: archive.deletingLastPathComponent()) {
                Task {
                    let controller = TransferController(title: String(localized: "Packing"),
                                                        failureTitle: String(localized: "Packing failed"), window: window)
                    _ = await controller.run(source: source.directory.path, target: archive.path) { progress, _ in
                        try? FileManager.default.removeItem(at: archive)
                        try await ArchiveWriter.pack(names, in: source.directory, to: archive, progress: progress)
                        return []
                    }
                    self.leftPanel.reread()
                    self.rightPanel.reread()
                }
            }
        }
    }

    private func unpack(_ archives: [(url: URL, paths: [String], base: String, destination: URL)], total: Int64?) {
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
                    try await ArchiveReader.extract(archive.url, paths: archive.paths, base: archive.base,
                                                    to: archive.destination, progress: progress)
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

    /// Ctrl+Left/Right: shows the folder under the cursor (or the current folder)
    /// in the given panel; pressed towards the active panel itself, it shows the
    /// other panel's folder there.
    @objc(cm_TransferLeft:)
    func transferLeft(_ sender: Any?) {
        transfer(to: leftPanel)
    }

    @objc(cm_TransferRight:)
    func transferRight(_ sender: Any?) {
        transfer(to: rightPanel)
    }

    private func transfer(to target: FilePanelController) {
        let source = target === activePanel ? inactivePanel : activePanel
        var directory = source.directory
        if source === activePanel, let item = source.listView.currentItem, item.isFolder {
            directory = item.isParent ? source.directory.deletingLastPathComponent() : item.url
        }
        target.load(directory)
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
        FindFilesWindowController.show(searchingIn: activePanel.directory, goTo: { [weak self] url in
            guard let self else { return }
            activePanel.load(url.deletingLastPathComponent(), selecting: url.lastPathComponent)
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
    /// the cursors of both panels. Different text files open in FileMerge.
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
        guard pair.count == 2, leftPanel.archive == nil, rightPanel.archive == nil, let window = view.window else {
            NSSound.beep()
            return
        }
        let (a, b) = (pair[0].url, pair[1].url)
        Task {
            let difference = await Self.firstDifference(a, b)
            guard let difference else {
                Prompt.info(String(localized: "The files are identical."), message: "\(a.path)\n\(b.path)", in: window)
                return
            }
            let opendiff = URL(filePath: "/usr/bin/opendiff")
            if ListerWindowController.defaultMode(for: a) == .text, ListerWindowController.defaultMode(for: b) == .text,
               FileManager.default.isExecutableFile(atPath: opendiff.path) {
                let process = Process()
                process.executableURL = opendiff
                process.arguments = [a.path, b.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            } else {
                Prompt.info(String(localized: "The files differ."),
                            message: String(localized: "First difference at byte \(difference)."), in: window)
            }
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

    /// ⌘K: mounts a network share and shows it in the active panel.
    @objc func connectToServer(_ sender: Any?) {
        guard let window = view.window else { return }
        let key = "LastServerAddress"
        Prompt.text(String(localized: "Connect to Server"),
                    message: String(localized: "Server address (sftp://, smb://, afp://, nfs://, https:// for WebDAV):"),
                    initial: AppDefaults.store.string(forKey: key) ?? "smb://",
                    okTitle: String(localized: "Connect"), in: window) { [weak self] address in
            guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
                NSSound.beep()
                return
            }
            AppDefaults.store.set(address, forKey: key)
            if let fileSystem = SFTPFileSystem(url: url, password: nil) {
                self?.activePanel.openRemote(fileSystem)
                return
            }
            Task {
                do {
                    let mountPoint = try await NetworkConnection.mount(url)
                    self?.activePanel.load(mountPoint)
                } catch {
                    Prompt.error(String(localized: "Cannot connect to \u{201C}\(address)\u{201D}"), error, in: window)
                }
            }
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
        // Leave the volume in both panels first, so nothing keeps it busy.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for panel in [leftPanel, rightPanel] where panel.directory.path.hasPrefix(volume.path) {
            panel.load(home)
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
        guard let volume = Volume.containing(activePanel.directory, in: Volume.mounted())?.url,
              volume.path != "/" else { return nil }
        let values = try? volume.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey,
                                                         .volumeIsLocalKey])
        let ejectable = values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
            || values?.volumeIsLocal == false
        return ejectable ? volume : nil
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
        let position = splitView.arrangedSubviews[0].frame.width
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == Command.switchHidSys.selector {
            menuItem.state = showsHidden ? .on : .off
        } else if menuItem.action == Command.srcQuickView.selector {
            menuItem.state = quickView == nil ? .off : .on
        } else if menuItem.action == #selector(ejectVolume(_:)) {
            return ejectableVolume != nil
        } else if menuItem.action == Command.srcTree.selector {
            menuItem.state = treePanel == nil ? .off : .on
        }
        return true
    }
}

extension MainViewController: FilePanelControllerDelegate {
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
        savePanels()
        let showTabs = leftPanel.tabs.count > 1 || rightPanel.tabs.count > 1
        leftPanel.alwaysShowsTabBar = showTabs
        rightPanel.alwaysShowsTabBar = showTabs
        if panel === activePanel {
            commandLine.view.directory = panel.directory
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
