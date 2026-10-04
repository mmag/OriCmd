import AppKit
import os

@MainActor
protocol FilePanelControllerDelegate: AnyObject {
    func filePanelDidBecomeActive(_ panel: FilePanelController)
    func filePanelSwitchPanel(_ panel: FilePanelController)
    func filePanelDidChangeDirectory(_ panel: FilePanelController)
    func filePanelCursorDidMove(_ panel: FilePanelController)
    func filePanel(_ panel: FilePanelController, interceptKey event: NSEvent) -> Bool
    /// Whether a tab other than `panel`'s active one (in either panel) shows `server`.
    func filePanel(_ panel: FilePanelController, otherTabsShow server: String) -> Bool
    /// A server address typed into the path bar: connect to it, as Connect to Server.
    func filePanel(_ panel: FilePanelController, openAddress address: String)
    /// A drive button's "Open in Other Panel".
    func filePanel(_ panel: FilePanelController, openDriveInOtherPanel url: URL)
    /// A drive button's "Eject": the volume is left in both panels first.
    func filePanel(_ panel: FilePanelController, eject volume: URL)
    /// A tab of the other panel dropped on this one's tab bar: that tab, taken out of
    /// the other panel (or a copy of it, when it is the other panel's only one).
    func filePanel(_ panel: FilePanelController, takeTab id: UUID) -> FilePanelController.Tab?
}

/// Owns one panel: its current directory, listing, sort order and view.
///
/// As a view controller it sits in the responder chain right after its
/// panel view, so `cm_*` commands sent to the focused file list reach it.
final class FilePanelController: NSViewController {
    let panelView = PanelView()
    weak var delegate: FilePanelControllerDelegate?

    private(set) var directory: URL
    private var entries: [FileItem] = []
    /// The order `entries` are already sorted in (big folders are sorted in the background).
    private var entriesOrder: SortOrder?

    /// Where the panel is inside an archive, while browsing one.
    struct ArchiveLocation {
        let url: URL
        var folder: String
        var entries: [ArchiveEntry]
        /// Size and date of the archive file when `entries` were read.
        var stamp: [Int64] = []
        /// For an archive inside an archive: the outer one, as it was shown. `url` is
        /// then a temporary copy, so the archive is read-only.
        var outer: OuterArchive?

        /// The archive itself, as the path bar shows it (outer.zip/inner.zip inside another).
        var rootPath: String { outer.map { $0.location.displayPath + "/" + $0.name } ?? url.path }

        var displayPath: String { folder.isEmpty ? rootPath : rootPath + "/" + folder }

        /// Whether files can be added, renamed or deleted in it.
        var isWritable: Bool { outer == nil && ArchiveEditor.isWritable(url) }

        /// Archive paths of entries shown in the current folder.
        func path(of name: String) -> String {
            folder.isEmpty ? name : folder + "/" + name
        }
    }

    /// The archive an archive inside it was opened from, and that one's name there.
    final class OuterArchive {
        let location: ArchiveLocation
        let name: String

        init(location: ArchiveLocation, name: String) {
            self.location = location
            self.name = name
        }
    }

    /// Set while the panel shows the inside of an archive (read-only).
    private(set) var archive: ArchiveLocation?
    private var lastMask = "*.*"
    private var watcher: DirectoryWatcher?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    struct HistoryEntry {
        let directory: URL
        let selectedName: String?
    }

    /// A folder tab: everything that differs between tabs of one panel.
    struct Tab {
        /// Finds the tab again after an asynchronous question (indices may change).
        let id = UUID()
        var directory: URL
        var selectedName: String?
        var sortOrder: SortOrder
        var backHistory: [HistoryEntry] = []
        var forwardHistory: [HistoryEntry] = []
        /// The server shown in the tab, with its terminal: both stay while other tabs
        /// are shown (`directory` is the local folder the tab goes back to).
        var remote: RemoteLocation?
        var terminal: ShellTerminalView?
        var showsTerminal = false
        var lock = Lock.none
        /// The folder a locked tab keeps (or comes back to).
        var lockedDirectory: URL?
        /// A name given to the tab, shown instead of its folder's.
        var name: String?

        /// Total Commander's locked tabs: one that keeps its folder (going elsewhere
        /// opens a new tab), or one that comes back to it when chosen again.
        enum Lock: Int {
            case none, locked, allowsChanges
        }

        /// The folder's name (or the server folder's), or the tab's own; a locked tab
        /// is marked with *, as in Total Commander.
        var title: String {
            let folder: String
            if let remote {
                let name = (remote.path as NSString).lastPathComponent
                folder = name.isEmpty || name == "/" ? remote.fileSystem.displayName : name
            } else {
                folder = directory.path == "/" ? "/" : directory.lastPathComponent
            }
            return (lock == .none ? "" : "*") + (name ?? folder)
        }
    }

    private static let historyLimit = 50
    private var backHistory: [HistoryEntry] = []
    private var forwardHistory: [HistoryEntry] = []

    private(set) var tabs: [Tab]
    private(set) var activeTabIndex: Int

    /// Shows the tab bar even for a single tab, so both panels line up
    /// when the other one has tabs.
    var alwaysShowsTabBar = false {
        didSet { if alwaysShowsTabBar != oldValue { updateTabBar() } }
    }

    var sortOrder = SortOrder() {
        didSet {
            panelView.headerView.sortOrder = sortOrder
            if sortOrder.column.needsMetadata && entries.count > 100 && entriesOrder != sortOrder {
                sortInBackground()
            } else {
                refreshList(selecting: listView.currentItem?.name)
            }
        }
    }

    /// Sorting by a metadata column reads every file; for bigger folders that
    /// happens in the background and the list is re-sorted when done.
    private func sortInBackground() {
        let order = sortOrder
        let entries = self.entries
        let generation = loadGeneration
        Task {
            let sorted = await Self.sort(entries, by: order)
            // Dropped if the folder was reloaded or another order chosen meanwhile.
            guard generation == loadGeneration, sortOrder == order else { return }
            self.entries = sorted
            entriesOrder = order
            refreshList(selecting: listView.currentItem?.name)
        }
    }

    @concurrent
    private nonisolated static func sort(_ entries: [FileItem], by order: SortOrder) async -> [FileItem] {
        order.sorted(entries)
    }

    var showsHidden = false {
        didSet { refreshList(selecting: listView.currentItem?.name) }
    }

    /// Ctrl+B: lists all files of the folder and its subfolders, with relative names.
    private(set) var isBranchView = false

    /// Find Files → "Feed to Panel": the found files, listed instead of the folder.
    private var searchResults: (title: String, urls: [URL])?

    /// A server (SFTP, FTP) shown in the panel.
    struct RemoteLocation {
        let fileSystem: any RemoteFileSystem
        var path: String

        var displayPath: String { fileSystem.displayName + (path.hasPrefix("/") ? path : "/" + path) }

        func path(of name: String) -> String {
            RemotePath.join(path, name)
        }
    }

    private(set) var remote: RemoteLocation?

    var searchResultsShown: Bool { searchResults != nil }

    /// Show → Filter: only files matching this mask are listed (folders always are).
    private var filterMask: String? {
        didSet {
            updatePathMask()
            refreshList(selecting: listView.currentItem?.name)
        }
    }

    /// Ctrl+S quick filter: only names containing this text are listed.
    private var quickFilter: String? {
        didSet {
            guard quickFilter != oldValue else { return }
            updatePathMask()
            refreshList(selecting: listView.currentItem?.name)
        }
    }

    /// The column set chosen for this panel (nil: the Default view); folders that
    /// match a set's masks show that set anyway.
    var chosenColumnSet: String? {
        didSet { applyColumnSet() }
    }

    /// cm_ShowOnlySelected: only these names are listed, until another folder is
    /// shown or All Files is chosen.
    private var onlyNames: Set<String>? {
        didSet {
            guard onlyNames != oldValue else { return }
            updatePathMask()
            refreshList(selecting: listView.currentItem?.name)
        }
    }

    /// Whether the quick search box currently edits the quick filter.
    private var quickSearchFilters = false

    private func updatePathMask() {
        let mask = quickFilter.map { "*\($0)*" } ?? filterMask ?? "*.*"
        panelView.pathBar.mask = onlyNames == nil ? mask : mask + " " + String(localized: "[selected only]")
    }

    var listView: FileListView { panelView.listView }

    var viewMode: FileListView.ViewMode {
        get { listView.viewMode }
        set { panelView.setViewMode(newValue) }
    }

    var isActive: Bool {
        get { panelView.isActive }
        set { panelView.isActive = newValue }
    }

    /// Creates a panel with a tab for each directory.
    convenience init(tabDirectories: [URL], activeTab: Int = 0) {
        self.init(tabs: tabDirectories.map { Tab(directory: $0, sortOrder: SortOrder()) }, activeTab: activeTab)
    }

    init(tabs: [Tab], activeTab: Int = 0) {
        let tabs = tabs.isEmpty ? [Tab(directory: FileManager.default.homeDirectoryForCurrentUser, sortOrder: SortOrder())] : tabs
        let active = min(max(activeTab, 0), tabs.count - 1)
        directory = tabs[active].directory
        self.tabs = tabs
        activeTabIndex = active
        super.init(nibName: nil, bundle: nil)

        listView.delegate = self
        panelView.headerView.sortOrder = sortOrder
        panelView.headerView.onColumnClicked = { [weak self] column in self?.sort(by: column) }
        panelView.headerView.onChooseColumnSet = { [weak self] name in self?.chooseColumnSet(name) }
        panelView.pathBar.onClick = { [weak self] in self?.focus() }
        panelView.pathBar.editableText = { [weak self] in self?.editablePath ?? "" }
        panelView.pathBar.onCommit = { [weak self] text in self?.go(to: text) }
        panelView.pathBar.completions = { [weak self] text in await self?.completions(for: text) ?? [] }
        panelView.onGoToRoot = { [weak self] in self?.goToRoot() }
        panelView.onGoToParent = { [weak self] in self?.goToParent() }
        panelView.onVolumeSelected = { [weak self] volume in self?.openDrive(volume.url) }
        panelView.driveBar.onSelect = { [weak self] url in self?.openDrive(url) }
        panelView.driveBar.menuProvider = { [weak self] url in self?.driveMenu(for: url) }
        panelView.setDriveBarVisible(Settings.showsDriveButtons)
        panelView.tabBar.onSelect = { [weak self] index in self?.selectTab(index) }
        panelView.tabBar.onClose = { [weak self] index in self?.closeTab(index) }
        panelView.tabBar.onContextMenu = { [weak self] index in self?.tabMenu(for: index) }
        panelView.tabBar.onNewTab = { [weak self] in self?.openNewTab(nil) }
        panelView.tabBar.onDropTab = { [weak self] id, index in self?.dropTab(id, at: index) ?? false }
        panelView.quickSearchField.delegate = self
        panelView.terminalPane.onFocus = { [weak self] in
            guard let self else { return }
            terminalWasFocused = true
            delegate?.filePanelDidBecomeActive(self)
        }
        panelView.terminalPane.onReconnect = { [weak self] in self?.openTerminal(focusing: true) }
        panelView.terminalPane.onEndedAtOnce = { [weak self] terminal in
            // An account without a shell (sftp only): the terminal opened by connecting hides again.
            guard let self, terminal.opensQuietly, terminal === panelView.terminalPane.terminal else { return }
            hideTerminal()
        }

        load(directory)
        updateTabBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = panelView
    }

    /// Marked entries, or the entry under the cursor when nothing is marked.
    var selectedItems: [FileItem] {
        let marked = listView.items.filter { listView.marked.contains($0.name) }
        if !marked.isEmpty { return marked }
        if let current = listView.currentItem, !current.isParent { return [current] }
        return []
    }

    /// Font or other appearance settings changed.
    func settingsDidChange() {
        applyColumnSet()
        panelView.setDriveBarVisible(Settings.showsDriveButtons)
        // Setting the font clears the terminal's selection: only when it changed.
        for terminal in terminals where terminal.font != TerminalPane.font {
            terminal.font = TerminalPane.font
        }
        listView.settingsDidChange()
        refreshList(selecting: listView.currentItem?.name, fallback: listView.cursor)
        panelView.pathBar.needsDisplay = true
        panelView.headerView.needsDisplay = true
    }

    func focus() {
        panelView.window?.makeFirstResponder(listView)
    }

    // MARK: - Navigation

    /// Reads `directory` and shows it, placing the cursor on `name` if given.
    /// The folder is read in the background (a slow network volume must not
    /// freeze the window); only the latest request is shown. Esc cancels it.
    func load(_ directory: URL, selecting name: String? = nil, recordingHistory: Bool = true,
              then completion: (() -> Void)? = nil) {
        if remote != nil {
            leaveServer { [weak self] in
                self?.load(directory, selecting: name, recordingHistory: recordingHistory, then: completion)
            }
            return
        }
        let directory = directory.standardizedFileURL
        leaveLockedTab(for: directory)
        if directory != self.directory {
            isBranchView = false
        }
        let branch = isBranchView
        let includingHidden = showsHidden
        let sortOrder = sortOrder
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task {
            let showsIndicator = Task {
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled && generation == loadGeneration { panelView.setLoading(true) }
            }
            let result = await Self.read(directory, branch: branch, includingHidden: includingHidden,
                                         sortOrder: sortOrder)
            showsIndicator.cancel()
            guard generation == loadGeneration else { return }
            panelView.setLoading(false)
            switch result {
            case .success(let listing):
                show(listing, of: directory, selecting: name, recordingHistory: recordingHistory)
                completion?()
            case .failure(let error):
                if !(error is CancellationError) {
                    present(error, reading: directory)
                }
            }
        }
    }

    /// Esc while a folder is being read: stops reading and keeps the old listing.
    override func cancelOperation(_ sender: Any?) {
        guard loadTask != nil else {
            quickFilter = nil
            return
        }
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        panelView.setLoading(false)
    }

    /// What a background read produces.
    private struct Listing: Sendable {
        let entries: [FileItem]
        let sortOrder: SortOrder
        let volumes: [Volume]
        let freeSpace: String
    }

    @concurrent
    private nonisolated static func read(_ directory: URL, branch: Bool, includingHidden: Bool,
                                         sortOrder: SortOrder) async -> Result<Listing, Error> {
        do {
            var entries = try DirectoryListing.items(in: directory)
            if branch {
                entries = DirectoryListing.branchItems(in: directory, includingHidden: includingHidden)
            }
            try Task.checkCancellation()
            entries = sortOrder.sorted(entries)
            try Task.checkCancellation()
            return .success(Listing(entries: entries, sortOrder: sortOrder, volumes: Volume.mounted(),
                                    freeSpace: VolumeSpace(for: directory)?.summary ?? ""))
        } catch {
            return .failure(error)
        }
    }

    private func show(_ listing: Listing, of directory: URL, selecting name: String?, recordingHistory: Bool) {
        loadTask = nil
        let entries = listing.entries
        if searchResults != nil {
            searchResults = nil
            panelView.pathBar.showsMask = true
            listView.setMarked([])
        }
        clearRemote()
        if archive != nil {
            archive = nil
            listView.setMarked([])
        }
        let isNewDirectory = directory != self.directory
        if isNewDirectory {
            listView.folderSizes = [:]
            quickFilter = nil
            onlyNames = nil
            if recordingHistory {
                backHistory.append(HistoryEntry(directory: self.directory, selectedName: listView.currentItem?.name))
                backHistory = Array(backHistory.suffix(Self.historyLimit))
                forwardHistory.removeAll()
            }
            listView.setMarked([])
        }
        self.directory = directory
        self.entries = entries
        entriesOrder = listing.sortOrder
        if isNewDirectory || watcher == nil {
            watcher = DirectoryWatcher(url: directory) { [weak self] in self?.reread() }
        }
        panelView.show(directory: directory, volumes: listing.volumes, freeSpace: listing.freeSpace)
        applyColumnSet()
        refreshList(selecting: name, fallback: isNewDirectory ? 0 : listView.cursor)
        tabs[activeTabIndex].directory = directory
        updateTabBar()
        delegate?.filePanelDidChangeDirectory(self)
    }

    // MARK: - Servers

    /// Connects to a server and shows its first folder in this panel.
    func openRemote(_ fileSystem: any RemoteFileSystem, leftServer: Bool = false, onConnected: (() -> Void)? = nil) {
        leaveLockedTab(for: nil)
        if remote != nil {
            // Another server in this tab: the terminal of the one shown ends first.
            leaveServer { [weak self] in self?.openRemote(fileSystem, leftServer: true, onConnected: onConnected) }
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        panelView.setLoading(true)
        loadTask = Task {
            do {
                let path = try await fileSystem.connect()
                guard generation == loadGeneration else { return }
                listView.setMarked([])
                remote = RemoteLocation(fileSystem: fileSystem, path: path)
                onConnected?()
                loadTask = nil
                loadRemote(path, selecting: nil)
                updateTabBar()
                if fileSystem is SFTPFileSystem, Self.opensTerminal {
                    openTerminal(focusing: false)
                }
            } catch {
                panelView.setLoading(false)
                loadTask = nil
                // The server left for this one is gone: the tab shows its local folder again.
                if leftServer, generation == loadGeneration { load(directory) }
                if !(error is CancellationError) {
                    Prompt.error(String(localized: "Cannot connect to \u{201C}\(fileSystem.displayName)\u{201D}"), error,
                                 in: view.window)
                }
            }
        }
    }

    /// Lists a folder on the server in the background.
    private func loadRemote(_ path: String, selecting name: String?) {
        guard let fileSystem = remote?.fileSystem else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task {
            let indicator = Task {
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled && generation == loadGeneration { panelView.setLoading(true) }
            }
            defer {
                indicator.cancel()
                if generation == loadGeneration {
                    panelView.setLoading(false)
                    loadTask = nil
                }
            }
            do {
                let items = try await fileSystem.list(path)
                guard generation == loadGeneration, let current = remote, current.fileSystem === fileSystem else { return }
                let isNewFolder = path != current.path
                remote?.path = path
                if isNewFolder {
                    listView.setMarked([])
                    updateTabBar()
                }
                entries = items
                entriesOrder = nil
                panelView.pathBar.showsMask = false
                panelView.pathBar.path = remote?.displayPath ?? path
                refreshList(selecting: name, fallback: isNewFolder ? 0 : listView.cursor)
                delegate?.filePanelDidChangeDirectory(self)
            } catch {
                if !(error is CancellationError) {
                    Prompt.error(String(localized: "Cannot read \u{201C}\(path)\u{201D}"), error, in: view.window)
                }
            }
        }
    }

    /// Runs a change on the server, then lists the folder again.
    private func runOnServer(selecting name: String?, _ change: @escaping @Sendable () async throws -> Void) {
        guard let remote else { return }
        Task {
            do {
                try await change()
            } catch {
                Prompt.error(String(localized: "The server reported an error"), error, in: view.window)
            }
            loadRemote(remote.path, selecting: name)
        }
    }

    /// Downloads one file of the server into a new temporary folder.
    private func downloadToTemporaryFolder(_ item: FileItem) async -> URL? {
        guard let remote, let window = view.window else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "OriCmd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = remote.path(of: item.name)
        let controller = TransferController(title: String(localized: "Downloading"),
                                            failureTitle: String(localized: "Download failed"), window: window)
        let done = await controller.run(source: path, target: folder.path) { progress, _ in
            // A new, empty folder: nothing to ask about.
            _ = try await remote.fileSystem.download([item], from: remote.path, to: folder, progress: progress,
                                                     conflicts: RemoteConflicts(nil))
            return [folder]
        }
        return done.isEmpty ? nil : folder.appending(path: item.name)
    }

    /// Uploads local files into the server folder shown here (or `folder`);
    /// moving deletes the originals afterwards.
    func upload(_ urls: [URL], to folder: String? = nil, moving: Bool, then finished: (() -> Void)? = nil) {
        guard let remote, let window = view.window else { return }
        let target = folder ?? remote.path
        Task {
            let controller = TransferController(title: String(localized: "Uploading"),
                                                failureTitle: String(localized: "Upload failed"), window: window)
            let done = await controller.run(source: urls.first?.deletingLastPathComponent().path ?? "",
                                            target: remote.fileSystem.displayName + target) { progress, resolveConflict in
                let completed = try await remote.fileSystem.upload(urls, to: target, progress: progress,
                                                                   conflicts: RemoteConflicts(resolveConflict))
                // Moving deletes only what reached the server completely.
                if moving {
                    try await FileOperations.deletePermanently(urls.filter(completed.contains))
                }
                return urls.filter(completed.contains)
            }
            if !done.isEmpty {
                loadRemote(remote.path, selecting: urls.first?.lastPathComponent)
            }
            finished?()
        }
    }

    /// Downloads entries of the server folder shown here into a local folder;
    /// moving deletes them on the server afterwards. Returns whether it worked.
    func download(_ items: [FileItem], to folder: URL, moving: Bool) async -> Bool {
        guard let remote, let window = view.window else { return false }
        let controller = TransferController(title: String(localized: "Downloading"),
                                            failureTitle: String(localized: "Download failed"), window: window)
        let completed = OSAllocatedUnfairLock(initialState: Set<String>())
        let done = await controller.run(source: remote.displayPath, target: folder.path) { progress, resolveConflict in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let names = try await remote.fileSystem.download(items, from: remote.path, to: folder, progress: progress,
                                                             conflicts: RemoteConflicts(resolveConflict))
            completed.withLock { $0 = names }
            // Moving deletes on the server only what arrived completely (skipped files stay).
            if moving {
                try await remote.fileSystem.delete(items.filter { names.contains($0.name) }, in: remote.path)
            }
            return [folder]
        }
        if !done.isEmpty {
            listView.setMarked(listView.marked.subtracting(completed.withLock { $0 }))
            if moving {
                loadRemote(remote.path, selecting: nil)
            }
        }
        return !done.isEmpty
    }

    /// Net → Disconnect: leaves the server and shows the local folder again.
    @objc(cm_FtpDisconnect:)
    func ftpDisconnect(_ sender: Any?) {
        guard let fileSystem = remote?.fileSystem else {
            NSSound.beep()
            return
        }
        leaveServer { [weak self] in
            guard let self else { return }
            // The connection is shared by every tab of the server (in both panels): it
            // closes when no other tab shows the server.
            if delegate?.filePanel(self, otherTabsShow: fileSystem.displayName) != true {
                fileSystem.disconnect()
            }
            load(directory)
        }
    }

    /// A drive button (or the volume list) on a server tab opens the drive in a new
    /// tab: the server keeps its tab.
    func openDrive(_ url: URL) {
        if remote != nil {
            openTab(url)
        } else {
            load(url)
        }
    }

    /// Leaves the server shown in this tab: its terminal ends, after asking when a
    /// program still runs there. Without a server `proceed` runs at once.
    func leaveServer(then proceed: @escaping () -> Void) {
        guard remote != nil else {
            proceed()
            return
        }
        let fileSystem = remote?.fileSystem
        let tab = activeTabIndex
        confirmClosing([panelView.terminalPane.terminal].compactMap { $0 }) { [weak self] in
            // Nothing is left if the tab or its server changed meanwhile.
            guard let self, activeTabIndex == tab, remote?.fileSystem === fileSystem else { return }
            closeTerminal()
            clearRemote()
            proceed()
        }
    }

    /// The tab shows no server any more. The server's entries are dropped at once:
    /// until the local folder is listed they would stand for local paths.
    private func clearRemote() {
        guard remote != nil else { return }
        remote = nil
        entries = []
        entriesOrder = nil
        panelView.pathBar.showsMask = true
        listView.setMarked([])
        refreshList(selecting: nil)
        updateTabBar()
    }

    /// Whether a tab of this panel shows the server named `name` ("sftp://user@host").
    func showsServer(_ name: String, excludingActiveTab: Bool) -> Bool {
        tabs.indices.contains { index in
            index == activeTabIndex
                ? !excludingActiveTab && remote?.fileSystem.displayName == name
                : tabs[index].remote?.fileSystem.displayName == name
        }
    }

    /// The local folder is going away (a volume was ejected): the panel goes to `url`,
    /// a server tab only changes the folder it goes back to.
    func leaveLocalFolder(for url: URL) {
        if remote != nil {
            directory = url
        } else {
            load(url)
        }
    }

    // MARK: - Server terminal

    private static let terminalShownKey = "ServerTerminalShown"

    /// Whether connecting to a server shows its terminal: the last choice made with ⌃`.
    private static var opensTerminal: Bool {
        get { AppDefaults.store.object(forKey: terminalShownKey) as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: terminalShownKey) }
    }

    /// The terminal had the focus: its commands may have changed the folder,
    /// which is read again when the files get the focus back.
    private var terminalWasFocused = false

    /// A session is being started; the focus goes to it when ready if asked for.
    private var terminalStart: (fileSystem: SFTPFileSystem, focusing: Bool)?

    /// The terminals of the panel's tabs (the active tab's is the one shown).
    var terminals: [ShellTerminalView] {
        terminals(ofTabs: Array(tabs.indices))
    }

    /// Shows the terminal, starting a shell in the panel's folder unless one is running.
    private func openTerminal(focusing: Bool) {
        guard let remote, let fileSystem = remote.fileSystem as? SFTPFileSystem else {
            NSSound.beep()
            return
        }
        let pane = panelView.terminalPane
        panelView.setTerminalVisible(true)
        if pane.isRunning {
            if focusing { pane.focus() }
            return
        }
        if let start = terminalStart, start.fileSystem === fileSystem {
            terminalStart?.focusing = start.focusing || focusing
            return
        }
        terminalStart = (fileSystem, focusing)
        Task {
            do {
                let command = try await fileSystem.shellCommand(in: remote.path)
                guard let start = terminalStart, start.fileSystem === fileSystem else { return }
                terminalStart = nil
                if let ended = pane.terminal { pane.close(ended) }
                let terminal = pane.start(command, over: fileSystem)
                terminal.opensQuietly = !start.focusing
                if start.focusing { pane.focus() }
            } catch {
                guard terminalStart?.fileSystem === fileSystem else { return }
                terminalStart = nil
                hideTerminal()
                Prompt.error(String(localized: "Cannot connect to \u{201C}\(fileSystem.displayName)\u{201D}"), error,
                             in: view.window)
            }
        }
    }

    /// Hides the terminal of the tab (its shell keeps running); the files get the focus.
    private func hideTerminal() {
        if panelView.terminalPane.hasFocus { focus() }
        panelView.setTerminalVisible(false)
    }

    /// Ends the terminal of the tab and hides it.
    private func closeTerminal() {
        terminalStart = nil
        hideTerminal()
        if let terminal = panelView.terminalPane.terminal {
            panelView.terminalPane.close(terminal)
        }
    }

    /// Runs `proceed` once `terminals` may be closed: when programs still run in
    /// them, the user is asked first.
    func confirmClosing(_ terminals: [ShellTerminalView], proceed: @escaping () -> Void) {
        guard terminals.contains(where: \.isRunning) else {
            proceed()
            return
        }
        Task {
            let programs = await Self.runningPrograms(in: terminals)
            guard !programs.isEmpty, let window = view.window else {
                proceed()
                return
            }
            Prompt.confirm(Self.runningTitle(programs),
                           message: programs.count == 1
                               ? String(localized: "Closing the terminal stops it on the server.")
                               : String(localized: "Closing the terminals stops them on the server."),
                           okTitle: String(localized: "Close Terminal"), in: window, completion: proceed)
        }
    }

    /// The programs running in `terminals` instead of their shells, asked of the servers at once.
    static func runningPrograms(in terminals: [ShellTerminalView]) async -> [String] {
        let checks = terminals.filter(\.isRunning).map { terminal in
            Task { await terminal.runningProgram() }
        }
        var programs: [String] = []
        for check in checks {
            if let program = await check.value { programs.append(program) }
        }
        return programs
    }

    /// "“apt” is still running in the terminal".
    /// The quotes are the language's own (“btop” in English, «btop» in Russian).
    static func runningTitle(_ programs: [String]) -> String {
        if programs.count == 1 {
            return programs[0] == ShellTerminalView.fullScreenProgram
                ? String(localized: "A full-screen program is still running in the terminal")
                : String(localized: "\u{201C}\(programs[0])\u{201D} is still running in the terminal")
        }
        let names = programs.map { name in
            name == ShellTerminalView.fullScreenProgram
                ? name : String(localized: "program.quoted", defaultValue: "\u{201C}\(name)\u{201D}")
        }
        return String(localized: "Programs are still running in terminals: \(names.joined(separator: ", "))")
    }

    /// ⌃`: shows the terminal of the server and moves the focus there; from the
    /// terminal, hides it and goes back to the files (the shell keeps running).
    @objc(cm_ServerTerminal:)
    func serverTerminal(_ sender: Any?) {
        if panelView.terminalPane.hasFocus {
            hideTerminal()
            Self.opensTerminal = false
        } else {
            Self.opensTerminal = true
            openTerminal(focusing: true)
        }
    }

    /// ⌃⌥`: goes to the panel's folder in the terminal. The `cd` is typed only at the
    /// shell's prompt, which is cleared first (⌃E ⌃U); a program running there would
    /// take it as input. The leading space keeps it out of the shell's history.
    @objc(cm_TerminalChangeDir:)
    func terminalChangeDir(_ sender: Any?) {
        let pane = panelView.terminalPane
        guard let remote, let terminal = pane.terminal, terminal.isRunning,
              !remote.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            NSSound.beep()
            return
        }
        panelView.setTerminalVisible(true)
        Task {
            if let program = await terminal.runningProgram() {
                Prompt.info(Self.runningTitle([program]),
                            message: String(localized: "The folder can be changed when it finishes."), in: view.window)
                return
            }
            guard terminal === pane.terminal, terminal.isRunning else { return }
            terminal.send(txt: "\u{05}\u{15} cd " + UserCommand.quoted(remote.path) + "\r")
        }
    }

    // MARK: - The path bar

    /// What a click on the path bar gives to edit: the folder, the server folder
    /// (sftp://…/folder), or the folder inside the archive.
    private var editablePath: String {
        if let remote { return remote.displayPath }
        if let archive { return archive.displayPath }
        return directory.path
    }

    /// Goes to the text typed into the path bar: a folder on this Mac (a file is shown
    /// selected in its folder, an archive opens), a folder on the server or in the
    /// archive shown, or another server's address.
    private func go(to typed: String) {
        focus()
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let remote {
            let server = remote.fileSystem.displayName
            if Self.isOnServer(text, server) {
                let path = String(text.dropFirst(server.count))
                loadRemote(path.isEmpty ? "/" : path, selecting: nil)
                return
            }
            if text.hasPrefix("/") {
                loadRemote(text, selecting: nil)
                return
            }
        }
        if text.contains("://") {
            delegate?.filePanel(self, openAddress: text)
            return
        }
        if let archive, text == archive.rootPath || text.hasPrefix(archive.rootPath + "/") {
            let inner = String(text.dropFirst(archive.rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard inner.isEmpty || archive.entries.contains(where: { $0.path == inner || $0.path.hasPrefix(inner + "/") }) else {
                NSSound.beep()
                return
            }
            self.archive?.folder = inner
            showArchiveFolder(selecting: nil)
            return
        }
        let url = URL(filePath: (text as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            Prompt.info(String(localized: "\u{201C}\(text)\u{201D} was not found"), message: "", in: view.window)
            return
        }
        if isDirectory.boolValue {
            load(url)
        } else if ArchiveReader.isArchive(url.lastPathComponent) {
            openArchive(url)
        } else {
            load(url.deletingLastPathComponent(), selecting: url.lastPathComponent)
        }
    }

    /// "sftp://me@host/x" is on "sftp://me@host"; "sftp://me@host2/x" is not.
    private static func isOnServer(_ text: String, _ server: String) -> Bool {
        text == server || text.hasPrefix(server + "/")
    }

    /// Tab in the path bar: the entries of the folder typed whose names start with what
    /// follows the last "/" (full texts, folders ending in "/").
    private func completions(for text: String) async -> [String] {
        guard let slash = text.lastIndex(of: "/") else { return [] }
        let folderText = String(text[...slash])
        let start = String(text[text.index(after: slash)...]).lowercased()
        let includesHidden = showsHidden || start.hasPrefix(".")
        func matching(_ names: [(name: String, isFolder: Bool)]) -> [String] {
            names.filter { $0.name.lowercased().hasPrefix(start) && (includesHidden || !$0.name.hasPrefix(".")) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { folderText + $0.name + ($0.isFolder ? "/" : "") }
        }
        if let remote, Self.isOnServer(text, remote.fileSystem.displayName) || text.hasPrefix("/") {
            let server = remote.fileSystem.displayName
            let folder = Self.isOnServer(text, server) ? String(folderText.dropFirst(server.count)) : folderText
            guard let items = try? await remote.fileSystem.list(folder.isEmpty ? "/" : folder) else { return [] }
            return matching(items.filter { !$0.isParent }.map { ($0.name, $0.isDirectory) })
        }
        if let archive, text.hasPrefix(archive.rootPath + "/") {
            let inner = String(folderText.dropFirst(archive.rootPath.count + 1))
            var children: [String: Bool] = [:]
            for entry in archive.entries where entry.path.hasPrefix(inner) && entry.path.count > inner.count {
                let rest = entry.path.dropFirst(inner.count)
                let name = String(rest.prefix { $0 != "/" })
                children[name] = (children[name] ?? false) || rest.contains("/") || entry.isDirectory
            }
            return matching(children.map { ($0.key, $0.value) })
        }
        guard !text.contains("://") else { return [] }
        let folder = URL(filePath: (folderText as NSString).expandingTildeInPath)
        let names = await Task.detached {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
        }.value
        return matching(names.map { (name: $0.0, isFolder: $0.1) })
    }

    // MARK: - Search results

    /// Shows found files (named relative to `root` where possible) as the panel's
    /// listing; everything works on the real files, [..] returns to `root`.
    func showSearchResults(_ urls: [URL], root: URL, title: String, selecting name: String? = nil) {
        leaveLockedTab(for: nil)
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let items = urls.compactMap { url -> FileItem? in
            let path = url.standardizedFileURL.path
            let shown = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            return DirectoryListing.item(atPath: path, named: shown)
        }
        if archive != nil {
            archive = nil
        }
        if searchResults == nil || directory != root.standardizedFileURL {
            listView.setMarked([])
        }
        directory = root.standardizedFileURL
        watcher = nil
        searchResults = (title, items.map(\.url))
        entries = items
        entriesOrder = nil
        panelView.show(directory: directory, volumes: Volume.mounted())
        panelView.pathBar.showsMask = false
        panelView.pathBar.path = title
        refreshList(selecting: name, fallback: 0)
        delegate?.filePanelDidChangeDirectory(self)
    }

    // MARK: - Archives

    /// Shows the contents of an archive as a folder (Enter / Ctrl+PgDn on it).
    /// Shows an archive as a folder. It is read in the background (a big tar.gz is
    /// decompressed as a whole), and a folder load still under way is dropped.
    /// `quietly`: a file tried as an archive whatever its name (Ctrl+PgDn); if it is
    /// none, nothing happens.
    func openArchive(_ url: URL, inside outer: OuterArchive? = nil, folder: String = "", selecting name: String? = nil,
                     quietly: Bool = false) {
        if archive == nil { leaveLockedTab(for: nil) }
        loadGeneration += 1
        let generation = loadGeneration
        // A folder still loading is dropped, with its indicator; Esc stops this one.
        loadTask?.cancel()
        loadTask = Task {
            let showsIndicator = Task {
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled && generation == loadGeneration { panelView.setLoading(true) }
            }
            defer {
                showsIndicator.cancel()
                if generation == loadGeneration {
                    panelView.setLoading(false)
                    loadTask = nil
                }
            }
            do {
                let (entries, stamp) = try await Self.readArchive(url)
                // An empty file passes for an empty archive: not unless named as one.
                guard !entries.isEmpty || !quietly else { throw CancellationError() }
                guard generation == loadGeneration else { return }
                listView.setMarked([])
                // A folder asked for that the archive does not have: its root.
                let known = folder.isEmpty || entries.contains { $0.path == folder || $0.path.hasPrefix(folder + "/") }
                archive = ArchiveLocation(url: url, folder: known ? folder : "", entries: entries, stamp: stamp, outer: outer)
                showArchiveFolder(selecting: known ? name : nil)
            } catch {
                // An archive in an archive was a temporary copy.
                if outer != nil { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                guard generation == loadGeneration, !quietly else { return }
                Prompt.error(String(localized: "Cannot open archive \u{201C}\(url.lastPathComponent)\u{201D}"), error,
                             in: view.window)
            }
        }
    }

    /// Shows here what the other panel `source` has under its cursor (Ctrl+Left/Right):
    /// a folder or an archive opened, a file in its folder, selected. Without
    /// `underCursor`, the folder (or archive folder) `source` shows. A server's folders
    /// and archives inside archives (temporary copies) stay where they are.
    func show(locationOf source: FilePanelController, underCursor: Bool) {
        let item = underCursor ? source.listView.currentItem : nil
        if source.remote != nil || source.archive?.outer != nil {
            NSSound.beep()
        } else if let archive = source.archive {
            var folder = archive.folder
            var name: String?
            if let item, item.isParent {
                guard !folder.isEmpty else {
                    load(archive.url.deletingLastPathComponent(), selecting: archive.url.lastPathComponent)
                    return
                }
                name = (folder as NSString).lastPathComponent
                folder = (folder as NSString).deletingLastPathComponent
            } else if let item, item.isDirectory {
                folder = archive.path(of: item.name)
            } else {
                name = item?.name
            }
            load(archive.url.deletingLastPathComponent(), selecting: archive.url.lastPathComponent) { [weak self] in
                self?.openArchive(archive.url, folder: folder, selecting: name)
            }
        } else if let item, item.isParent {
            load(source.directory.deletingLastPathComponent(), selecting: source.directory.lastPathComponent)
        } else if let item, item.isFolder {
            load(item.url)
        } else if let item {
            // Also a file of search results or the branch view: its own folder.
            let folder = item.url.deletingLastPathComponent()
            if !item.isDirectory, ArchiveReader.isArchive(item.name) {
                load(folder, selecting: item.url.lastPathComponent) { [weak self] in self?.openArchive(item.url) }
            } else {
                load(folder, selecting: item.url.lastPathComponent)
            }
        } else {
            load(source.directory)
        }
    }

    /// Reads the archive again, unless it has not changed since (the folder
    /// holding it may change for other reasons).
    private func reopenArchive(_ location: ArchiveLocation, selecting name: String? = nil, force: Bool = false) {
        if !force, !location.stamp.isEmpty, Self.stamp(of: location.url) == location.stamp {
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            let result = try? await Self.readArchive(location.url)
            guard generation == loadGeneration, archive?.url == location.url else { return }
            guard let (entries, stamp) = result else {
                load(directory)
                return
            }
            archive?.entries = entries
            archive?.stamp = stamp
            showArchiveFolder(selecting: name ?? listView.currentItem?.name)
        }
    }

    @concurrent
    private nonisolated static func readArchive(_ url: URL) async throws -> ([ArchiveEntry], [Int64]) {
        let stamp = stamp(of: url)
        return (try ArchiveReader.entries(of: url), stamp)
    }

    private nonisolated static func stamp(of url: URL) -> [Int64] {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return [] }
        return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
    }

    /// Changes the archive shown in this panel (with a progress sheet), then
    /// shows its new contents. `completion` receives whether it succeeded.
    func applyArchiveEdit(_ edit: ArchiveEditor.Edit, selecting name: String? = nil,
                          completion: ((Bool) -> Void)? = nil) {
        guard let archive, let window = view.window else { return }
        let url = archive.url
        Task {
            // An encrypted archive is changed with its password (and keeps it).
            let password: String?
            do {
                password = try await ArchivePasswords.password(for: url, entries: archive.entries, in: window)
            } catch {
                if !(error is CancellationError) {
                    Prompt.error(String(localized: "Cannot update archive"), error, in: window)
                }
                completion?(false)
                return
            }
            let controller = TransferController(title: String(localized: "Updating archive"),
                                                failureTitle: String(localized: "Cannot update archive"), window: window)
            let done = await controller.run(source: url.path, target: url.path) { progress, _ in
                do {
                    try await ArchiveEditor.apply(edit, to: url, password: password, progress: progress)
                } catch let error as ArchiveError where error.kind == .wrongPassword {
                    await ArchivePasswords.forget(url)
                    throw error
                }
                return [url]
            }
            if let current = self.archive, current.url == url {
                reopenArchive(current, selecting: name, force: true)
            }
            completion?(!done.isEmpty)
        }
    }

    /// Lists the current archive folder. Folders that only exist implicitly
    /// (as part of deeper paths) are shown too.
    private func showArchiveFolder(selecting name: String?) {
        guard let archive else { return }
        let prefix = archive.folder.isEmpty ? "" : archive.folder + "/"
        var children: [String: FileItem] = [:]
        // The order the archive has its entries in (for Unsorted).
        var order: [String] = []
        for entry in archive.entries where entry.path.hasPrefix(prefix) && entry.path.count > prefix.count {
            let rest = entry.path.dropFirst(prefix.count)
            let childName = String(rest.prefix { $0 != "/" })
            let isNested = rest.contains("/")
            if isNested && children[childName] != nil { continue }
            if children[childName] == nil { order.append(childName) }
            let isFolder = isNested || entry.isDirectory
            children[childName] = FileItem(
                name: childName, url: archive.url.appending(path: prefix + childName),
                isDirectory: isFolder, isPackage: false, isSymlink: false, isHidden: childName.hasPrefix("."),
                size: isFolder ? 0 : entry.size, modified: entry.modified,
                mode: isNested ? 0o755 : entry.mode
            )
        }
        entries = order.compactMap { children[$0] }
        entriesOrder = nil
        panelView.show(directory: directory, volumes: Volume.mounted())
        panelView.pathBar.path = archive.displayPath
        refreshList(selecting: name, fallback: 0)
        delegate?.filePanelDidChangeDirectory(self)
    }

    /// `asArchive`: Ctrl+PgDn, the file is tried as an archive whatever its name.
    private func openInArchive(_ item: FileItem, asArchive: Bool = false) {
        guard let archive else { return }
        if item.isParent {
            archiveGoUp()
        } else if item.isDirectory {
            self.archive?.folder = archive.path(of: item.name)
            showArchiveFolder(selecting: nil)
        } else if ArchiveReader.isArchive(item.name) || asArchive {
            // An archive in the archive opens as a folder too, from a temporary copy —
            // unless the panel went elsewhere while it was being extracted.
            let generation = loadGeneration
            Task {
                guard let url = await extractToTemporaryFolder(item) else { return }
                guard generation == loadGeneration, self.archive?.url == archive.url,
                      self.archive?.folder == archive.folder else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                openArchive(url, inside: OuterArchive(location: archive, name: item.name),
                            quietly: !ArchiveReader.isArchive(item.name))
            }
        } else {
            Task {
                if let url = await extractToTemporaryFolder(item) {
                    openFile(url)
                }
            }
        }
    }

    /// Up one folder inside the archive, or out of it at its root.
    private func archiveGoUp() {
        guard let archive else { return }
        if archive.folder.isEmpty, let outer = archive.outer {
            // Back to the outer archive; the temporary copy of this one goes.
            try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent())
            self.archive = outer.location
            showArchiveFolder(selecting: outer.name)
        } else if archive.folder.isEmpty {
            load(archive.url.deletingLastPathComponent(), selecting: archive.url.lastPathComponent, recordingHistory: false)
        } else {
            let name = (archive.folder as NSString).lastPathComponent
            self.archive?.folder = (archive.folder as NSString).deletingLastPathComponent
            showArchiveFolder(selecting: name)
        }
    }

    /// Extracts one entry of the archive into a new temporary folder.
    private func extractToTemporaryFolder(_ item: FileItem) async -> URL? {
        guard let archive else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "OriCmd-\(UUID().uuidString)")
        let path = archive.path(of: item.name)
        do {
            let password = try await ArchivePasswords.password(
                for: archive.url, entries: ArchivePasswords.entries(archive.entries, at: [path]), in: view.window)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try await ArchiveReader.extract(archive.url, paths: [path], base: archive.folder, to: folder,
                                                password: password, progress: TransferProgress())
            } catch let error as ArchiveError where error.kind == .wrongPassword {
                ArchivePasswords.forget(archive.url)
                throw error
            }
            return folder.appending(path: item.name)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: folder)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: folder)
            Prompt.error(String(localized: "Cannot unpack \u{201C}\(item.name)\u{201D}"), error, in: view.window)
            return nil
        }
    }

    /// Refuses changes inside archives that cannot be written (rar, iso, …).
    private func refuseReadOnlyArchive() -> Bool {
        guard let archive, !archive.isWritable else { return false }
        if archive.outer != nil {
            Prompt.info(String(localized: "An archive inside an archive is read-only"),
                        message: String(localized: "Copy it out of the outer archive (F5) to change it."), in: view.window)
            return true
        }
        Prompt.info(String(localized: "This archive is read-only"),
                    message: String(localized: "Only zip, tar, tar.gz, tar.bz2, tar.xz and 7z archives can be changed."),
                    in: view.window)
        return true
    }

    /// Refuses operations that are never available inside archives.
    private func refuseInsideArchive() -> Bool {
        if remote != nil {
            Prompt.info(String(localized: "Not supported on servers"),
                        message: String(localized: "Download the files first (F5)."), in: view.window)
            return true
        }
        guard archive != nil else { return false }
        Prompt.info(String(localized: "Not supported inside archives"),
                    message: String(localized: "Unpack the files first (F5), or use Alt+F5 to create a new archive."),
                    in: view.window)
        return true
    }

    // MARK: - Tabs

    /// The tabs as saved between launches: their folders (a locked tab's own one),
    /// locks and names, and the active tab.
    var tabState: SavedTabs {
        tabs[activeTabIndex] = currentTab()
        return SavedTabs(directories: tabs.map { ($0.lockedDirectory ?? $0.directory).path },
                         locks: tabs.map(\.lock.rawValue), names: tabs.map { $0.name ?? "" }, active: activeTabIndex)
    }

    /// Tabs of a panel kept in the defaults (between launches, or as favorites).
    struct SavedTabs {
        var directories: [String]
        var locks: [Int]
        var names: [String]
        var active: Int

        var dictionary: [String: Any] {
            ["tabs": directories, "locks": locks, "names": names, "active": active]
        }

        init(directories: [String], locks: [Int], names: [String], active: Int) {
            (self.directories, self.locks, self.names, self.active) = (directories, locks, names, active)
        }

        init(_ dictionary: [String: Any]?) {
            directories = dictionary?["tabs"] as? [String] ?? []
            locks = dictionary?["locks"] as? [Int] ?? []
            names = dictionary?["names"] as? [String] ?? []
            active = dictionary?["active"] as? Int ?? 0
        }

        /// The tabs whose folders still exist (the active one kept active if it does).
        func tabs(sortOrder: SortOrder) -> (tabs: [Tab], active: Int) {
            var tabs: [Tab] = []
            var activeIndex = 0
            for (index, path) in directories.enumerated() where FileManager.default.fileExists(atPath: path) {
                if index == active { activeIndex = tabs.count }
                var tab = Tab(directory: URL(filePath: path), sortOrder: sortOrder)
                tab.lock = locks.indices.contains(index) ? Tab.Lock(rawValue: locks[index]) ?? .none : .none
                tab.lockedDirectory = tab.lock == .none ? nil : tab.directory
                tab.name = names.indices.contains(index) && !names[index].isEmpty ? names[index] : nil
                tabs.append(tab)
            }
            return (tabs, activeIndex)
        }
    }

    /// Shows `saved` tabs instead of the panel's (asking first when a program still
    /// runs in a server terminal of a tab closed); none existing: nothing changes.
    func replaceTabs(with saved: SavedTabs) {
        let (newTabs, active) = saved.tabs(sortOrder: sortOrder)
        guard !newTabs.isEmpty else {
            NSSound.beep()
            return
        }
        confirmClosing(terminals(ofTabs: Array(tabs.indices))) { [weak self] in
            guard let self else { return }
            if panelView.terminalPane.hasFocus { focus() }
            terminals(ofTabs: Array(tabs.indices)).forEach(panelView.terminalPane.close)
            tabs = newTabs
            activateTab(at: active)
        }
    }

    /// A locked tab keeps its folder: before going to `target` (or anywhere else
    /// when nil, as into an archive or a server) a new tab opens beside it, and
    /// it goes there instead. A tab locked with folder changes allowed goes, except
    /// to a server.
    private func leaveLockedTab(for target: URL?) {
        let tab = tabs[activeTabIndex]
        guard tab.lock == .locked || (tab.lock == .allowsChanges && target == nil) else { return }
        if let target, target.standardizedFileURL == tab.lockedDirectory { return }
        tabs[activeTabIndex] = currentTab()
        var opened = Tab(directory: directory, sortOrder: sortOrder)
        opened.backHistory = backHistory
        opened.forwardHistory = forwardHistory
        tabs.insert(opened, at: activeTabIndex + 1)
        activeTabIndex += 1
        updateTabBar()
    }

    /// Locks the tab to its folder, or unlocks it.
    @objc(cm_ToggleLockCurrentTab:)
    func toggleLockCurrentTab(_ sender: Any?) {
        toggleLock(.locked, of: activeTabIndex)
    }

    /// cm_ToggleLockDcaCurrentTab: locked, but the folder may change; the tab comes
    /// back to its folder when chosen again.
    @objc(cm_ToggleLockDcaCurrentTab:)
    func toggleLockDcaCurrentTab(_ sender: Any?) {
        toggleLock(.allowsChanges, of: activeTabIndex)
    }

    /// Only a local folder (not a server, an archive or found files) is locked.
    private func toggleLock(_ lock: Tab.Lock, of index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index == activeTabIndex { tabs[index] = currentTab() }
        if tabs[index].lock == lock {
            tabs[index].lock = .none
            tabs[index].lockedDirectory = nil
        } else {
            guard canLock(index) else {
                NSSound.beep()
                return
            }
            tabs[index].lock = lock
            tabs[index].lockedDirectory = tabs[index].lockedDirectory ?? tabs[index].directory.standardizedFileURL
        }
        updateTabBar()
    }

    private func canLock(_ index: Int) -> Bool {
        index == activeTabIndex ? remote == nil && archive == nil && searchResults == nil : tabs[index].remote == nil
    }

    /// Asks for the tab's own name; an empty one shows the folder's again.
    private func renameTab(_ index: Int) {
        guard tabs.indices.contains(index), let window = view.window else { return }
        let id = tabs[index].id
        let shown = index == activeTabIndex ? currentTab() : tabs[index]
        var unnamed = shown
        unnamed.name = nil
        unnamed.lock = .none
        Prompt.text(String(localized: "Rename Tab"), message: String(localized: "The tab's name (empty: the folder's):"),
                    initial: shown.name ?? unnamed.title, okTitle: String(localized: "Rename"), in: window) { [weak self] text in
            guard let self, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            let name = text.trimmingCharacters(in: .whitespaces)
            tabs[index].name = name.isEmpty ? nil : name
            updateTabBar()
        }
    }

    /// Opens a tab for the local `directory` (a server is never in two tabs: from a
    /// server tab ⌘T opens the folder the tab goes back to).
    func openTab(_ directory: URL) {
        tabs[activeTabIndex] = currentTab()
        tabs.insert(Tab(directory: directory, sortOrder: sortOrder), at: activeTabIndex + 1)
        activateTab(at: activeTabIndex + 1)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        tabs[activeTabIndex] = currentTab()
        activateTab(at: index)
    }

    /// The last tab is never closed, as in Total Commander. A server tab's terminal
    /// ends with it (after asking when a program still runs there).
    func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else {
            NSSound.beep()
            return
        }
        let id = tabs[index].id
        confirmClosing(terminals(ofTabs: [index])) { [weak self] in
            guard let self, tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            if index == activeTabIndex, panelView.terminalPane.hasFocus { focus() }
            terminals(ofTabs: [index]).forEach(panelView.terminalPane.close)
            removeTab(index)
        }
    }

    private func removeTab(_ index: Int) {
        tabs.remove(at: index)
        if index == activeTabIndex {
            activateTab(at: min(index, tabs.count - 1))
        } else {
            if index < activeTabIndex { activeTabIndex -= 1 }
            updateTabBar()
            delegate?.filePanelDidChangeDirectory(self)
        }
    }

    private func tabMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let lock = tabs[index].lock
        for (title, action) in [(String(localized: "Close Tab"), #selector(closeTabFromMenu(_:))),
                                (String(localized: "Close Other Tabs"), #selector(closeOtherTabs(_:))),
                                (String(localized: "Duplicate Tab"), #selector(duplicateTab(_:))),
                                ("-", nil),
                                (Command.toggleLockCurrentTab.title, #selector(lockTabFromMenu(_:))),
                                (Command.toggleLockDcaCurrentTab.title, #selector(lockTabAllowingChangesFromMenu(_:))),
                                (String(localized: "Rename Tab…"), #selector(renameTabFromMenu(_:)))] as [(String, Selector?)] {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            switch action {
            case #selector(duplicateTab(_:)):
                item.isEnabled = !isServerTab(index)
            case #selector(lockTabFromMenu(_:)), #selector(lockTabAllowingChangesFromMenu(_:)):
                let mine: Tab.Lock = action == #selector(lockTabFromMenu(_:)) ? .locked : .allowsChanges
                item.state = lock == mine ? .on : .off
                item.isEnabled = lock == mine || canLock(index)
            case #selector(renameTabFromMenu(_:)):
                item.isEnabled = true
            default:
                item.isEnabled = tabs.count > 1
            }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc private func lockTabFromMenu(_ sender: NSMenuItem) {
        toggleLock(.locked, of: sender.tag)
    }

    @objc private func lockTabAllowingChangesFromMenu(_ sender: NSMenuItem) {
        toggleLock(.allowsChanges, of: sender.tag)
    }

    @objc private func renameTabFromMenu(_ sender: NSMenuItem) {
        renameTab(sender.tag)
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        closeTab(sender.tag)
    }

    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        selectTab(sender.tag)
        let keepID = tabs[activeTabIndex].id
        let otherIDs = Set(tabs.map(\.id)).subtracting([keepID])
        confirmClosing(terminals(ofTabs: tabs.indices.filter { $0 != activeTabIndex })) { [weak self] in
            // The tabs asked about are closed; any opened meanwhile stay.
            guard let self, let keep = tabs.firstIndex(where: { $0.id == keepID }) else { return }
            selectTab(keep)
            terminals(ofTabs: tabs.indices.filter { otherIDs.contains(tabs[$0].id) })
                .forEach(panelView.terminalPane.close)
            tabs.removeAll { otherIDs.contains($0.id) }
            activeTabIndex = tabs.firstIndex { $0.id == keepID } ?? 0
            updateTabBar()
            delegate?.filePanelDidChangeDirectory(self)
        }
    }

    /// Only local tabs are duplicated: a server stays in its own tab.
    @objc private func duplicateTab(_ sender: NSMenuItem) {
        guard !isServerTab(sender.tag) else { return }
        selectTab(sender.tag)
        openTab(directory)
    }

    private func isServerTab(_ index: Int) -> Bool {
        index == activeTabIndex ? remote != nil : tabs.indices.contains(index) && tabs[index].remote != nil
    }

    private func terminals(ofTabs indices: [Int]) -> [ShellTerminalView] {
        indices.compactMap { $0 == activeTabIndex ? panelView.terminalPane.terminal : tabs[$0].terminal }
    }

    /// The active tab as it is now.
    private func currentTab() -> Tab {
        var tab = tabs[activeTabIndex]
        tab.directory = directory
        tab.selectedName = listView.currentItem?.name
        tab.sortOrder = sortOrder
        tab.backHistory = backHistory
        tab.forwardHistory = forwardHistory
        tab.remote = remote
        tab.terminal = panelView.terminalPane.terminal
        tab.showsTerminal = panelView.isTerminalVisible
        return tab
    }

    /// Shows the tab: its local folder, or its server with the terminal as it was left.
    /// The terminal of the tab left keeps running there, hidden.
    private func activateTab(at index: Int) {
        activeTabIndex = index
        let tab = tabs[index]
        backHistory = tab.backHistory
        forwardHistory = tab.forwardHistory
        if sortOrder != tab.sortOrder {
            sortOrder = tab.sortOrder
        }
        terminalStart = nil
        if panelView.terminalPane.hasFocus { focus() }
        panelView.terminalPane.attach(tab.terminal)
        panelView.setTerminalVisible(tab.terminal != nil && tab.showsTerminal)
        if let server = tab.remote {
            // Nothing of the folder shown before stays (an archive, found files, a filter).
            archive = nil
            searchResults = nil
            isBranchView = false
            quickFilter = nil
            onlyNames = nil
            watcher = nil
            listView.folderSizes = [:]
            remote = server
            directory = tab.directory
            entries = []
            listView.setMarked([])
            panelView.pathBar.showsMask = false
            panelView.pathBar.path = server.displayPath
            refreshList(selecting: nil)
            loadRemote(server.path, selecting: tab.selectedName)
            if tab.terminal == nil, tab.showsTerminal {
                openTerminal(focusing: false)
            }
        } else {
            clearRemote()
            // A tab locked with folder changes allowed comes back to its folder.
            if tab.lock == .allowsChanges, let locked = tab.lockedDirectory, locked != tab.directory.standardizedFileURL {
                load(locked, recordingHistory: false)
            } else {
                load(tab.directory, selecting: tab.selectedName, recordingHistory: false)
            }
        }
        updateTabBar()
        delegate?.filePanelDidChangeDirectory(self)
    }

    /// The active tab's title follows the panel (a server folder, too).
    private func updateTabBar() {
        let titles = tabs.indices.map { $0 == activeTabIndex ? currentTab().title : tabs[$0].title }
        panelView.setTabs(titles, identifiers: tabs.map(\.id), selected: activeTabIndex,
                          visible: tabs.count > 1 || alwaysShowsTabBar)
    }

    // MARK: - Dragging tabs

    /// A tab dropped on the tab bar before `index`: one of this panel's moves there,
    /// the other panel's comes over (its server and terminal too) and is shown.
    private func dropTab(_ id: UUID, at index: Int) -> Bool {
        if let from = tabs.firstIndex(where: { $0.id == id }) {
            moveTab(from: from, to: index)
            return true
        }
        guard let tab = delegate?.filePanel(self, takeTab: id) else {
            NSSound.beep()
            return false
        }
        tabs[activeTabIndex] = currentTab()
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        activateTab(at: min(max(index, 0), tabs.count - 1))
        focus()
        return true
    }

    private func moveTab(from: Int, to index: Int) {
        let destination = index > from ? index - 1 : index
        guard destination != from else { return }
        tabs[activeTabIndex] = currentTab()
        let activeID = tabs[activeTabIndex].id
        tabs.insert(tabs.remove(at: from), at: min(max(destination, 0), tabs.count - 1))
        activeTabIndex = tabs.firstIndex { $0.id == activeID } ?? 0
        updateTabBar()
        delegate?.filePanelDidChangeDirectory(self)
    }

    /// The tab `id` as it is now, for the other panel: taken out of this one, or,
    /// when it is the only tab, copied (a server stays: it is never in two tabs).
    func giveTab(_ id: UUID) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = index == activeTabIndex ? currentTab() : tabs[index]
        guard tabs.count > 1 else {
            guard tab.remote == nil else { return nil }
            var copy = Tab(directory: tab.directory, sortOrder: tab.sortOrder)
            copy.selectedName = tab.selectedName
            copy.backHistory = tab.backHistory
            copy.forwardHistory = tab.forwardHistory
            return copy
        }
        // A terminal still starting would be left behind: the tab waits for it.
        guard index != activeTabIndex || terminalStart == nil else { return nil }
        if index == activeTabIndex, panelView.terminalPane.hasFocus { focus() }
        tabs[index] = tab
        removeTab(index)
        return tab
    }

    func goBack() {
        guard !backHistory.isEmpty else {
            NSSound.beep()
            return
        }
        // Leaving a server may be cancelled: the history changes only after that.
        if remote != nil {
            leaveServer { [weak self] in self?.goBack() }
            return
        }
        let entry = backHistory.removeLast()
        forwardHistory.append(HistoryEntry(directory: directory, selectedName: listView.currentItem?.name))
        load(entry.directory, selecting: entry.selectedName, recordingHistory: false)
    }

    func goForward() {
        guard !forwardHistory.isEmpty else {
            NSSound.beep()
            return
        }
        if remote != nil {
            leaveServer { [weak self] in self?.goForward() }
            return
        }
        let entry = forwardHistory.removeLast()
        backHistory.append(HistoryEntry(directory: directory, selectedName: listView.currentItem?.name))
        load(entry.directory, selecting: entry.selectedName, recordingHistory: false)
    }

    /// Recently visited folders, most recent first, without duplicates.
    var recentDirectories: [URL] {
        var seen: Set<URL> = [directory]
        return backHistory.reversed().map(\.directory).filter { seen.insert($0).inserted }
    }

    /// Reloads the current directory keeping cursor and marks, or moves up
    /// to the nearest existing folder if it has been removed.
    func reread() {
        if let remote {
            loadRemote(remote.path, selecting: listView.currentItem?.name)
            return
        }
        if let archive {
            reopenArchive(archive)
            return
        }
        if let searchResults {
            showSearchResults(searchResults.urls, root: directory, title: searchResults.title,
                              selecting: listView.currentItem?.name)
            return
        }
        var directory = self.directory
        while !FileManager.default.fileExists(atPath: directory.path) && directory.path != "/" {
            directory = directory.deletingLastPathComponent()
        }
        load(directory, selecting: listView.currentItem?.name)
    }

    /// Mounted volumes changed: refresh the volume list, leave a vanished volume.
    /// A volume was renamed: its mount point moved, and a folder shown on it moves
    /// along. Whether it did.
    func volumeWasRenamed(from old: URL, to new: URL) -> Bool {
        let path = directory.path, oldPath = old.path
        guard remote == nil, path == oldPath || path.hasPrefix(oldPath.hasSuffix("/") ? oldPath : oldPath + "/")
        else { return false }
        let rest = String(path.dropFirst(oldPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let moved = rest.isEmpty ? new : new.appending(path: rest)
        if let archive, archive.outer == nil {
            let inside = archive.url.path.dropFirst(oldPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = new.appending(path: inside)
            let folder = archive.folder
            load(moved, selecting: url.lastPathComponent, recordingHistory: false) { [weak self] in
                self?.openArchive(url, folder: folder)
            }
        } else {
            load(moved, selecting: listView.currentItem?.name, recordingHistory: false)
        }
        return true
    }

    func volumesDidChange() {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            leaveLocalFolder(for: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        panelView.show(directory: directory, volumes: Volume.mounted())
        if let remote {
            panelView.pathBar.path = remote.displayPath
        }
    }

    func goToParent() {
        if let remote {
            if remote.path == "/" {
                load(directory)
            } else {
                loadRemote(RemotePath.parent(of: remote.path), selecting: (remote.path as NSString).lastPathComponent)
            }
            return
        }
        if archive != nil {
            archiveGoUp()
            return
        }
        if searchResults != nil {
            load(directory)
            return
        }
        guard directory.path != "/" else { return }
        load(directory.deletingLastPathComponent(), selecting: directory.lastPathComponent)
    }

    func goToRoot() {
        if remote != nil {
            loadRemote("/", selecting: nil)
            return
        }
        if archive != nil {
            archive?.folder = ""
            showArchiveFolder(selecting: nil)
            return
        }
        let root = Volume.containing(directory, in: Volume.mounted())?.url ?? URL(filePath: "/")
        load(root)
    }

    func sort(by column: SortColumn) {
        if sortOrder.column == column, !sortOrder.isUnsorted {
            sortOrder.ascending.toggle()
        } else {
            sortOrder = SortOrder(column: column, ascending: true)
        }
    }

    private func refreshList(selecting name: String?, fallback: Int = 0) {
        if entriesOrder != sortOrder {
            // Metadata sorts of big folders happen in the background; until then the
            // list keeps its previous order.
            if sortOrder.column.needsMetadata && entries.count > 100 {
                sortInBackground()
            } else {
                entries = sortOrder.sorted(entries)
                entriesOrder = sortOrder
            }
        }
        var items = showsHidden ? entries : entries.filter { !$0.isHidden }
        // The ignore list hides local entries only (a server's and an archive's stay).
        if Settings.usesIgnoreList, remote == nil, archive == nil {
            let list = Settings.ignoreList
            if !list.isEmpty {
                items = items.filter { !Settings.ignores(name: $0.name, path: $0.url.path, in: list) }
            }
        }
        if let filterMask {
            items = items.filter { $0.isFolder || FileMask.matches($0.name, filterMask) }
        }
        if let quickFilter {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(quickFilter) }
        }
        if let onlyNames {
            items = items.filter { onlyNames.contains($0.name) }
        }
        if archive != nil || searchResults != nil || remote != nil || directory.path != "/" {
            items.insert(.parent(of: directory), at: 0)
        }
        let cursor = name.flatMap { name in items.firstIndex { $0.name == name } } ?? fallback
        listView.reload(items: items, cursor: cursor)
        updateStatus()
    }

    /// "0 k / 1 234 k in 0 / 12 file(s), 0 / 3 dir(s)"
    private func updateStatus() {
        let entries = listView.items.filter { !$0.isParent }
        let marked = listView.marked
        let files = entries.filter { !$0.isFolder }
        let markedFiles = files.filter { marked.contains($0.name) }
        let folders = entries.filter(\.isFolder)
        let markedFolderCount = folders.count { marked.contains($0.name) }
        // Calculated folder sizes count as well, as in Total Commander.
        let sizes = listView.folderSizes
        let markedFolderBytes = folders.filter { marked.contains($0.name) }.reduce(Int64(0)) { $0 + (sizes[$1.name] ?? 0) }
        let folderBytes = folders.reduce(Int64(0)) { $0 + (sizes[$1.name] ?? 0) }

        func kilobytes(_ files: [FileItem], plus extra: Int64) -> String {
            let bytes = files.reduce(extra) { $0 + $1.size }
            return ((bytes + 1023) / 1024).formatted(.number.grouping(.automatic))
        }
        let markedSize = kilobytes(markedFiles, plus: markedFolderBytes)
        let totalSize = kilobytes(files, plus: folderBytes)
        panelView.statusLabel.stringValue = String(localized:
            "\(markedSize) k / \(totalSize) k in \(markedFiles.count) / \(files.count) file(s), \(markedFolderCount) / \(folders.count) dir(s)")
    }

    private func askForMask(marking: Bool) {
        guard let window = view.window else { return }
        Prompt.text(marking ? String(localized: "Select files") : String(localized: "Unselect files"),
                    message: String(localized: "File mask, e.g. *.txt;*.md"),
                    initial: lastMask, in: window) { [weak self] mask in
            guard let self else { return }
            lastMask = mask
            let names = listView.items
                .filter { !$0.isParent && !$0.isFolder && FileMask.matches($0.name, mask) }
                .map(\.name)
            listView.setMarked(marking ? listView.marked.union(names) : listView.marked.subtracting(names))
        }
    }

    private func open(_ item: FileItem, enteringPackages: Bool) {
        if let remote {
            if item.isParent {
                goToParent()
            } else if item.isDirectory || item.isSymlink {
                loadRemote(remote.path(of: item.name), selecting: nil)
            } else if enteringPackages {
                // Ctrl+PgDn never starts a file; a server's archives are not browsed.
                NSSound.beep()
            } else {
                Task {
                    if let url = await downloadToTemporaryFolder(item) {
                        openFile(url)
                    }
                }
            }
        } else if archive != nil {
            openInArchive(item, asArchive: enteringPackages)
        } else if item.isParent {
            goToParent()
        } else if !item.isDirectory && (ArchiveReader.isArchive(item.name) || enteringPackages) {
            // Ctrl+PgDn tries any file as an archive (a .docx, a .jar, a zip named
            // otherwise) and never starts it; a file that is none stays as it is.
            openArchive(item.url, quietly: !ArchiveReader.isArchive(item.name))
        } else if item.isFolder || (enteringPackages && item.isDirectory) {
            load(item.url)
        } else {
            openFile(item.url)
        }
    }

    /// Enter on a file: its associated program, or the one macOS opens it with.
    private func openFile(_ url: URL) {
        if !FileAssociations.perform(.open, on: url, window: view.window) {
            NSWorkspace.shared.open(url)
        }
    }

    private func present(_ error: Error, reading directory: URL) {
        Prompt.error(String(localized: "Cannot read folder \u{201C}\(directory.path)\u{201D}"), error, in: view.window)
    }
}

// MARK: - Commands

extension FilePanelController: NSMenuItemValidation {
    @objc(cm_RereadSource:)
    func rereadSource(_ sender: Any?) {
        reread()
    }

    @objc(cm_GoToParent:)
    func goToParentCommand(_ sender: Any?) {
        goToParent()
    }

    @objc(cm_GoToRoot:)
    func goToRootCommand(_ sender: Any?) {
        goToRoot()
    }

    /// Brief view: names only, in columns.
    @objc(cm_SrcShort:)
    func srcShort(_ sender: Any?) {
        viewMode = .brief
        delegate?.filePanelDidChangeDirectory(self)
    }

    /// Thumbnails view: Quick Look previews in a grid.
    @objc(cm_SrcThumbs:)
    func srcThumbs(_ sender: Any?) {
        viewMode = .thumbnails
        delegate?.filePanelDidChangeDirectory(self)
    }

    /// Full view: one row per entry with size, date and attributes.
    @objc(cm_SrcLong:)
    func srcLong(_ sender: Any?) {
        viewMode = .full
        delegate?.filePanelDidChangeDirectory(self)
    }

    @objc(cm_OpenNewTab:)
    func openNewTab(_ sender: Any?) {
        openTab(directory)
    }

    /// Ctrl+Up: opens the folder under the cursor in a new tab. A server stays in its
    /// own tab: its folders are not opened in others.
    @objc(cm_OpenDirInNewTab:)
    func openDirInNewTab(_ sender: Any?) {
        guard remote == nil else {
            NSSound.beep()
            return
        }
        guard let item = listView.currentItem, item.isFolder else {
            openTab(directory)
            return
        }
        openTab(item.isParent ? directory.deletingLastPathComponent() : item.url)
    }

    @objc(cm_CloseCurrentTab:)
    func closeCurrentTab(_ sender: Any?) {
        closeTab(activeTabIndex)
    }

    @objc(cm_SwitchToNextTab:)
    func switchToNextTab(_ sender: Any?) {
        selectTab((activeTabIndex + 1) % tabs.count)
    }

    @objc(cm_SwitchToPreviousTab:)
    func switchToPreviousTab(_ sender: Any?) {
        selectTab((activeTabIndex + tabs.count - 1) % tabs.count)
    }

    /// Ctrl+D: pops up the favourite folders, with add/remove for the current one.
    @objc(cm_DirectoryHotlist:)
    func directoryHotlist(_ sender: Any?) {
        let menu = NSMenu()
        for path in Hotlist.directories {
            let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath,
                                  action: #selector(historyItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = URL(filePath: path)
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let current = directory.path
        let isListed = Hotlist.directories.contains(current)
        let name = tabs[activeTabIndex].title
        let toggle = NSMenuItem(title: isListed ? String(localized: "Remove \u{201C}\(name)\u{201D}") : String(localized: "Add \u{201C}\(name)\u{201D}"),
                                action: #selector(toggleHotlistEntry(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let configure = NSMenuItem(title: String(localized: "Configure…"), action: #selector(configureHotlist(_:)),
                                   keyEquivalent: "")
        configure.target = self
        menu.addItem(configure)
        let bar = panelView.pathBar
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bar.bounds.maxY), in: bar)
    }

    @objc private func configureHotlist(_ sender: Any?) {
        HotlistWindowController.shared.showWindow(sender)
    }

    @objc private func toggleHotlistEntry(_ sender: NSMenuItem) {
        Hotlist.toggle(directory.path)
    }

    @objc(cm_GoToPrevDir:)
    func goToPrevDir(_ sender: Any?) {
        goBack()
    }

    @objc(cm_GoToNextDir:)
    func goToNextDir(_ sender: Any?) {
        goForward()
    }

    /// Alt+Down: pops up the recently visited folders under the path bar.
    @objc(cm_DirectoryHistory:)
    func directoryHistory(_ sender: Any?) {
        let menu = NSMenu()
        for url in recentDirectories {
            let item = NSMenuItem(title: url.path, action: #selector(historyItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else {
            NSSound.beep()
            return
        }
        let bar = panelView.pathBar
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bar.bounds.maxY), in: bar)
    }

    @objc private func historyItemChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            load(url)
        }
    }

    /// Ctrl+M: renames the selected files with the Multi-Rename Tool.
    @objc(cm_MultiRenameFiles:)
    func multiRenameFiles(_ sender: Any?) {
        guard !refuseInsideArchive() else { return }
        let items = selectedItems
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        // In branch view and search results names carry their folder ("sub/file.txt"):
        // the tool works on the file names themselves.
        let plain = items.map { item in
            FileItem(name: item.url.lastPathComponent, url: item.url, isDirectory: item.isDirectory,
                     isPackage: item.isPackage, isSymlink: item.isSymlink, isHidden: item.isHidden,
                     size: item.size, modified: item.modified, mode: item.mode)
        }
        MultiRenameWindowController.show(for: plain) { [weak self] in self?.reread() }
    }

    // MARK: - Attributes

    /// ⌘I: changes permissions, hidden/locked flags and the date of the selection.
    /// Only what the user changes in the dialog is applied.
    @objc(cm_SetAttrib:)
    func setAttrib(_ sender: Any?) {
        guard !refuseInsideArchive(), let window = view.window else { return }
        let items = selectedItems
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        let infos: [stat] = items.map { item in
            var info = stat()
            lstat(item.url.path, &info)
            return info
        }
        func initialState(_ test: (stat) -> Bool) -> NSControl.StateValue {
            let values = Set(infos.map(test))
            return values.count > 1 ? .mixed : (values.first == true ? .on : .off)
        }
        func checkbox(_ title: String, _ state: NSControl.StateValue) -> NSButton {
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.allowsMixedState = true
            box.state = state
            return box
        }

        let bits = AttributeChange.permissionBits
        let permissionBoxes = bits.map { bit in checkbox("", initialState { $0.st_mode & bit != 0 }) }
        let hiddenBox = checkbox(String(localized: "Hidden"), initialState { $0.st_flags & UInt32(UF_HIDDEN) != 0 })
        let lockedBox = checkbox(String(localized: "Locked"), initialState { $0.st_flags & UInt32(UF_IMMUTABLE) != 0 })
        let dateBox = NSButton(checkboxWithTitle: String(localized: "Modification date:"), target: nil, action: nil)
        let datePicker = NSDatePicker()
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        datePicker.dateValue = items[0].modified
        let subfoldersBox = NSButton(checkboxWithTitle: String(localized: "Include subfolders"), target: nil, action: nil)
        subfoldersBox.isEnabled = items.contains(where: \.isFolder)
        let initialStates = permissionBoxes.map(\.state) + [hiddenBox.state, lockedBox.state]

        let columnTitles = [String(localized: "Read"), String(localized: "Write"), String(localized: "Execute")]
        var rows: [[NSView]] = [[NSGridCell.emptyContentView] + columnTitles.map { NSTextField(labelWithString: $0) }]
        let rowTitles = [String(localized: "Owner"), String(localized: "Group"), String(localized: "Others")]
        for (row, title) in rowTitles.enumerated() {
            let boxes: [NSView] = Array(permissionBoxes[(row * 3)..<(row * 3 + 3)])
            rows.append([NSTextField(labelWithString: title)] + boxes)
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        for column in 1..<4 { grid.column(at: column).xPlacement = .center }
        let stack = NSStackView(views: [grid, NSStackView(views: [hiddenBox, lockedBox]),
                                        NSStackView(views: [dateBox, datePicker]), subfoldersBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.frame.size = stack.fittingSize

        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? String(localized: "Change attributes of \u{201C}\(items[0].name)\u{201D}")
            : String(localized: "Change attributes of \(items.count) files/folders")
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Apply"))
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var change = AttributeChange()
            for (index, box) in permissionBoxes.enumerated() where box.state != initialStates[index] && box.state != .mixed {
                change.permissions[bits[index]] = box.state == .on
            }
            if hiddenBox.state != initialStates[9] && hiddenBox.state != .mixed { change.hidden = hiddenBox.state == .on }
            if lockedBox.state != initialStates[10] && lockedBox.state != .mixed { change.locked = lockedBox.state == .on }
            if dateBox.state == .on { change.modified = datePicker.dateValue }
            change.includesSubfolders = subfoldersBox.state == .on
            let finalChange = change
            let urls = items.map(\.url)
            Task {
                let controller = TransferController(title: String(localized: "Changing attributes"),
                                                    failureTitle: String(localized: "Cannot change attributes"),
                                                    window: window)
                _ = await controller.run(source: urls[0].path, target: "") { progress, _ in
                    try await finalChange.apply(to: urls, progress: progress)
                    return urls
                }
                self.reread()
            }
        }
    }

    // MARK: - Checksums

    /// Creates a checksum file (MD5, SHA-1, SHA-256 or SHA-512) for the selection.
    @objc(cm_CRCcreate:)
    func crcCreate(_ sender: Any?) {
        guard !refuseInsideArchive(), let window = view.window else { return }
        let items = selectedItems
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        let algorithms = ChecksumAlgorithm.allCases
        Prompt.choice(String(localized: "Create Checksum File"),
                      message: String(localized: "Algorithm for the checksum file:"),
                      options: algorithms.map(\.title), selected: 2,
                      okTitle: String(localized: "Create"), in: window) { [weak self] index in
            guard let self else { return }
            let algorithm = algorithms[index]
            let baseName = items.count == 1 ? items[0].name : (tabs[activeTabIndex].title)
            let output = directory.appending(path: baseName + "." + algorithm.rawValue)
            let directory = directory
            Task {
                let controller = TransferController(title: String(localized: "Calculating checksums"),
                                                    failureTitle: String(localized: "Cannot create checksums"),
                                                    window: window)
                _ = await controller.run(source: directory.path, target: output.path) { progress, _ in
                    try await Checksums.create(for: items.map(\.url), relativeTo: directory, algorithm: algorithm,
                                               output: output, progress: progress)
                    return [output]
                }
                self.load(self.directory, selecting: output.lastPathComponent)
            }
        }
    }

    /// Verifies the checksum file under the cursor and reports the result.
    @objc(cm_CRCcheck:)
    func crcCheck(_ sender: Any?) {
        guard !refuseInsideArchive(), let window = view.window,
              let item = listView.currentItem, !item.isFolder,
              Checksums.fileExtensions.contains(item.fileExtension.lowercased()) else {
            NSSound.beep()
            return
        }
        let result = ChecksumVerification()
        Task {
            let controller = TransferController(title: String(localized: "Verifying checksums"),
                                                failureTitle: String(localized: "Cannot verify checksums"),
                                                window: window)
            let done = await controller.run(source: item.url.path, target: directory.path) { progress, _ in
                try await Checksums.verify(item.url, into: result, progress: progress)
                return [item.url]
            }
            guard !done.isEmpty else { return }
            let state = result.snapshot
            let problems = state.failed.map { String(localized: "Mismatch: \($0)") }
                + state.missing.map { String(localized: "Missing: \($0)") }
            let summary = String(localized:
                "\(state.passed) OK, \(state.failed.count) mismatched, \(state.missing.count) missing")
            Prompt.info(problems.isEmpty ? String(localized: "All checksums match") : summary,
                        message: problems.isEmpty ? summary : problems.prefix(30).joined(separator: "\n"),
                        in: window)
        }
    }

    // MARK: - Selection by extension, filter

    /// Ctrl+B: toggles the branch view (all files in all subfolders).
    @objc(cm_BranchView:)
    func branchView(_ sender: Any?) {
        guard !refuseInsideArchive() else { return }
        isBranchView.toggle()
        listView.setMarked([])
        load(directory, selecting: listView.currentItem?.name)
    }

    /// Alt+Num+: marks all files with the extension of the file under the cursor.
    @objc(cm_SelectCurrentExtension:)
    func selectCurrentExtension(_ sender: Any?) {
        markCurrentExtension(true)
    }

    /// Alt+Num−: unmarks all files with the extension of the file under the cursor.
    @objc(cm_UnselectCurrentExtension:)
    func unselectCurrentExtension(_ sender: Any?) {
        markCurrentExtension(false)
    }

    private func markCurrentExtension(_ mark: Bool) {
        guard let current = listView.currentItem, !current.isParent, !current.isFolder else {
            NSSound.beep()
            return
        }
        let ext = current.fileExtension.lowercased()
        let names = listView.items.filter { !$0.isFolder && $0.fileExtension.lowercased() == ext }.map(\.name)
        listView.setMarked(mark ? listView.marked.union(names) : listView.marked.subtracting(names))
    }

    /// Show → Filter: lists only files matching a mask, e.g. "*.jpg;*.png".
    @objc(cm_SrcUserSpec:)
    func srcUserSpec(_ sender: Any?) {
        guard let window = view.window else { return }
        Prompt.text(String(localized: "Filter"), message: String(localized: "Show only files matching (e.g. *.jpg;*.png):"),
                    initial: filterMask ?? "*.*", okTitle: String(localized: "Filter"), in: window) { [weak self] mask in
            let mask = mask.trimmingCharacters(in: .whitespaces)
            self?.filterMask = mask.isEmpty || mask == "*" || mask == "*.*" ? nil : mask
        }
    }

    // MARK: - Column sets

    /// The Full view columns for the folder shown (a server's: the chosen set).
    func applyColumnSet() {
        let set = ColumnSet.set(for: remote == nil ? directory : nil, chosen: chosenColumnSet)
        listView.columns = set.columns
        panelView.headerView.columns = set.columns
        panelView.headerView.columnSet = set.name
    }

    private func chooseColumnSet(_ name: String) {
        chosenColumnSet = name.isEmpty ? nil : name
    }

    /// Show → Columns: a set chosen in the menu (its name in the item).
    @objc func chooseColumnSetFromMenu(_ sender: Any?) {
        chooseColumnSet((sender as? NSMenuItem)?.representedObject as? String ?? "")
    }

    /// The set the panel shows ("" the Default view), for the menu's check mark.
    var columnSetShown: String { panelView.headerView.columnSet }

    /// Show → Unsorted (Ctrl+F7): the entries in the order the folder is read in;
    /// the folder is read again, since the order shown is a sorted one.
    @objc(cm_SrcUnsorted:)
    func srcUnsorted(_ sender: Any?) {
        guard !sortOrder.isUnsorted else { return }
        sortOrder = SortOrder(column: .name, ascending: true, isUnsorted: true)
        if archive != nil, let location = archive {
            reopenArchive(location, selecting: listView.currentItem?.name, force: true)
        } else {
            reread()
        }
    }

    /// Show → All Files: removes the filter (and Only Selected Files).
    @objc(cm_SrcAllFiles:)
    func srcAllFiles(_ sender: Any?) {
        onlyNames = nil
        filterMask = nil
    }

    /// Show → Only Selected Files: the others are hidden (again: all are shown).
    @objc(cm_ShowOnlySelected:)
    func showOnlySelected(_ sender: Any?) {
        if onlyNames != nil {
            onlyNames = nil
            return
        }
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else {
            NSSound.beep()
            return
        }
        onlyNames = Set(names)
    }

    // MARK: - Clipboard

    /// Files cut with ⌘X: pasting them (while the clipboard is unchanged) moves them.
    private static var cutClipboard: (changeCount: Int, urls: [URL])?

    @objc func copy(_ sender: Any?) {
        writeSelectionToClipboard(cut: false)
    }

    @objc func cut(_ sender: Any?) {
        writeSelectionToClipboard(cut: true)
    }

    @objc func paste(_ sender: Any?) {
        pasteFiles(moving: false)
    }

    /// ⌥⌘V, like Finder's "Move Item Here".
    @objc func moveItemsHere(_ sender: Any?) {
        pasteFiles(moving: true)
    }

    private func writeSelectionToClipboard(cut: Bool) {
        let urls = selectedItems.map(\.url)
        guard archive == nil, remote == nil, !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = AppDefaults.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        Self.cutClipboard = cut ? (pasteboard.changeCount, urls) : nil
    }

    private var clipboardFiles: [URL] {
        (AppDefaults.pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func pasteFiles(moving forceMove: Bool) {
        let pasteboard = AppDefaults.pasteboard
        // Files another program promised (Remote Desktop, virtual machines) come from the
        // program itself: the file URLs next to the promise point to placeholders.
        if PromisedFiles.areOffered(on: pasteboard) {
            pastePromisedFiles(from: pasteboard.name)
            return
        }
        let urls = clipboardFiles
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let moving = forceMove || Self.cutClipboard?.changeCount == pasteboard.changeCount
        if moving { Self.cutClipboard = nil }
        whenWritten(urls) { [weak self] in self?.paste(urls, moving: moving) }
    }

    /// Runs `proceed` once the programs that put `urls` on the clipboard (or drag them)
    /// have written them (see FileCoordination). A wait longer than half a second
    /// shows "Receiving Files…" with Cancel.
    private func whenWritten(_ urls: [URL], then proceed: @escaping () -> Void) {
        guard let window = view.window else { return }
        let waiting = Task { try await FileCoordination.waitUntilWritten(urls) }
        let progress = ProgressSheet()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !progress.isFinished else { return }
            progress.close = Prompt.progress(String(localized: "Receiving Files…"), in: window) { waiting.cancel() }
        }
        Task {
            let result = await waiting.result
            progress.finish()
            switch result {
            case .success:
                proceed()
            case .failure(let error) where !(error is CancellationError):
                Prompt.error(String(localized: "Cannot paste the files"), error, in: window)
            case .failure:
                break
            }
        }
    }

    private func paste(_ urls: [URL], moving: Bool) {
        if remote != nil {
            upload(urls, moving: moving)
            return
        }
        if let archive {
            guard !refuseReadOnlyArchive() else { return }
            applyArchiveEdit(.add(urls, folder: archive.folder), selecting: urls.first?.lastPathComponent) { succeeded in
                guard succeeded, moving else { return }
                Task { try? await FileOperations.deletePermanently(urls) }
            }
            return
        }
        transfer(urls, to: directory, moving: moving)
    }

    /// Asks the program that copied them for the promised files, into a private folder
    /// on this folder's volume, then moves them in (or uploads them, or adds them to
    /// the archive). The program may take a while: Cancel stops waiting for it.
    private func pastePromisedFiles(from pasteboard: NSPasteboard.Name) {
        guard let window = view.window, !refuseReadOnlyArchive() else { return }
        let base = remote == nil && archive == nil ? directory : FileManager.default.temporaryDirectory
        guard let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                         appropriateFor: base, create: true) else {
            NSSound.beep()
            return
        }
        let cleanUp: () -> Void = { try? FileManager.default.removeItem(at: folder) }
        var cancelled = false
        let closeProgress = Prompt.progress(String(localized: "Receiving Files…"),
                                            in: window) { cancelled = true }
        Task {
            let result = await Task.detached { try PromisedFiles.receive(from: pasteboard, into: folder) }.result
            closeProgress()
            guard !cancelled else {
                cleanUp()
                return
            }
            switch result {
            case .failure(let error):
                cleanUp()
                Prompt.error(String(localized: "Cannot paste the files"), error, in: window)
            case .success(let files) where files.isEmpty:
                cleanUp()
                NSSound.beep()
            case .success(let files):
                deliver(files, then: cleanUp)
            }
        }
    }

    /// Moves received files from a private folder to where the panel is.
    private func deliver(_ files: [URL], then finished: @escaping () -> Void) {
        if remote != nil {
            upload(files, moving: true, then: finished)
        } else if let archive {
            applyArchiveEdit(.add(files, folder: archive.folder), selecting: files.first?.lastPathComponent) { _ in
                finished()
            }
        } else {
            transfer(files, to: directory, moving: true, then: finished)
        }
    }

    /// Copies or moves files into `destination` (paste, drag and drop). Items
    /// already in that folder are duplicated as "name copy" instead.
    private func transfer(_ urls: [URL], to destination: URL, moving: Bool, then finished: (() -> Void)? = nil) {
        guard let window = view.window else { return }
        Task {
            let controller = moving
                ? TransferController(title: String(localized: "Moving"), failureTitle: String(localized: "Moving failed"),
                                     window: window)
                : TransferController(title: String(localized: "Copying"), failureTitle: String(localized: "Copying failed"),
                                     window: window)
            var options = TransferOptions()
            options.skipsDSStore = Settings.copySkipsDSStore
            _ = await controller.run(source: urls[0].deletingLastPathComponent().path, target: destination.path) {
                [options] progress, resolveConflict in
                let total = urls.reduce(Int64(0)) { $0 + TransferEngine.totalSize(of: $1) }
                progress.update { $0.totalBytes = total }
                // Items from another folder go in one job, so "Overwrite All" / "Skip All"
                // hold for all of them; items of this folder become "name copy".
                var others: [URL] = []
                for url in urls {
                    guard url.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path else {
                        others.append(url)
                        continue
                    }
                    if moving { continue }
                    let job = TransferJob(kind: .copy, sources: [url], destination: destination,
                                          newName: Self.copyName(for: url.lastPathComponent, in: destination), options: options)
                    _ = try await TransferEngine(job: job, progress: progress, reportsTotal: false,
                                                 resolveConflict: resolveConflict).run()
                }
                if !others.isEmpty {
                    let job = TransferJob(kind: moving ? .move : .copy, sources: others, destination: destination, newName: nil,
                                          options: options)
                    _ = try await TransferEngine(job: job, progress: progress, reportsTotal: false,
                                                 resolveConflict: resolveConflict).run()
                }
                return urls
            }
            load(directory, selecting: urls.first?.lastPathComponent)
            finished?()
        }
    }

    /// "name copy.ext", "name copy 2.ext", … — the first name not taken in `folder`.
    nonisolated static func copyName(for name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 1... {
            let candidate = index == 1 ? "\(base) copy" : "\(base) copy \(index)"
            let full = ext.isEmpty ? candidate : candidate + "." + ext
            if !FileManager.default.fileExists(atPath: folder.appending(path: full).path) {
                return full
            }
        }
        return name
    }

    /// Copies the names of the selected entries to the clipboard, one per line.
    @objc(cm_CopyNamesToClip:)
    func copyNamesToClip(_ sender: Any?) {
        copyToClipboard(selectedItems.map(\.name))
    }

    /// ⌥⌘C: copies the full paths of the selected entries, like Finder's "Copy as Pathname".
    @objc(cm_CopyFullNamesToClip:)
    func copyFullNamesToClip(_ sender: Any?) {
        let prefix = archive.map { $0.displayPath + "/" }
        copyToClipboard(selectedItems.map { item in prefix.map { $0 + item.name } ?? item.url.path })
    }

    /// Files → Print File List: the entries shown (the marked ones, when some are).
    @objc(cm_PrintDir:)
    func printDir(_ sender: Any?) {
        printList(subfolders: false)
    }

    /// Files → Print File List with Subfolders: the files inside the folders too.
    @objc(cm_PrintDirSub:)
    func printDirSub(_ sender: Any?) {
        printList(subfolders: true)
    }

    private func printList(subfolders: Bool) {
        let items = listView.marked.isEmpty ? listView.items : selectedItems
        Printing.print(Printing.list(items, in: directory, subfolders: subfolders && archive == nil && remote == nil),
                       title: panelView.pathBar.path, in: view.window)
    }

    /// Files → Print File: the text of the file under the cursor.
    @objc(cm_PrintFile:)
    func printFile(_ sender: Any?) {
        guard archive == nil, remote == nil, let item = listView.currentItem, !item.isParent, !item.isDirectory,
              let data = try? Data(contentsOf: item.url, options: .alwaysMapped), TextDecoding.looksLikeText(data) else {
            NSSound.beep()
            return
        }
        Printing.print(TextDecoding.string(from: data), title: item.name, in: view.window)
    }

    /// Ctrl+Z: the Finder comment of the file under the cursor, changed (empty:
    /// removed); the Comment column shows it.
    @objc(cm_CommentFiles:)
    func commentFiles(_ sender: Any?) {
        guard archive == nil, remote == nil, let item = listView.currentItem, !item.isParent,
              let window = view.window else {
            NSSound.beep()
            return
        }
        Prompt.text(String(localized: "Comment"), message: String(localized: "The comment of \u{201C}\(item.name)\u{201D}:"),
                    initial: FinderComment.read(item.url) ?? "", okTitle: String(localized: "OK"), in: window) {
            [weak self] text in
            do {
                try FinderComment.write(text.trimmingCharacters(in: .whitespacesAndNewlines), to: item.url)
                MetadataCache.shared.forget(item.url)
                self?.listView.needsDisplay = true
            } catch {
                Prompt.error(String(localized: "Cannot change the comment"), error, in: window)
            }
        }
    }

    /// The names (or full paths) with the size, the modification date and the
    /// permissions, tab-separated, one entry per line (a folder's size when calculated).
    @objc(cm_CopyDetailsToClip:)
    func copyDetailsToClip(_ sender: Any?) {
        copyToClipboard(selectedItems.map { details(of: $0, fullPath: false) })
    }

    @objc(cm_CopyFullDetailsToClip:)
    func copyFullDetailsToClip(_ sender: Any?) {
        copyToClipboard(selectedItems.map { details(of: $0, fullPath: true) })
    }

    private static let detailsDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func details(of item: FileItem, fullPath: Bool) -> String {
        let name = fullPath ? archive.map { $0.displayPath + "/" + item.name } ?? item.url.path : item.name
        let size = item.isFolder ? listView.folderSizes[item.name].map(String.init) ?? "" : String(item.size)
        let kind = item.isSymlink ? "l" : item.isDirectory ? "d" : "-"
        return [name, size, Self.detailsDateFormat.string(from: item.modified), kind + item.permissions]
            .joined(separator: "\t")
    }

    /// The names of the selected entries saved in a text file, one per line.
    @objc(cm_SaveSelectionToFile:)
    func saveSelectionToFile(_ sender: Any?) {
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else {
            NSSound.beep()
            return
        }
        chooseFile(saving: String(localized: "selection.txt")) { [weak self] url in
            do {
                try (names.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Prompt.error(String(localized: "Cannot save the selection"), error, in: self?.view.window)
            }
        }
    }

    /// Selects the entries named in a text file (names, or paths of this folder's entries).
    @objc(cm_LoadSelectionFromFile:)
    func loadSelectionFromFile(_ sender: Any?) {
        chooseFile(saving: nil) { [weak self] url in
            do {
                self?.select(lines: try String(contentsOf: url, encoding: .utf8))
            } catch {
                Prompt.error(String(localized: "Cannot read the selection"), error, in: self?.view.window)
            }
        }
    }

    /// Selects the entries named on the clipboard, one per line.
    @objc(cm_LoadSelectionFromClip:)
    func loadSelectionFromClip(_ sender: Any?) {
        guard let text = AppDefaults.pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        select(lines: text)
    }

    /// Marks the entries shown whose names (or paths in this folder) are lines of `text`.
    private func select(lines text: String) {
        let folder = directory.standardizedFileURL.path
        let names = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("/") else { return line.isEmpty ? nil : line }
            let url = URL(filePath: line).standardizedFileURL
            return url.deletingLastPathComponent().path == folder ? url.lastPathComponent : nil
        })
        let shown = listView.items.filter { !$0.isParent && names.contains($0.name) }.map(\.name)
        guard !shown.isEmpty else {
            NSSound.beep()
            return
        }
        listView.setMarked(Set(shown))
        updateStatus()
    }

    /// A file to save to (with a suggested name) or to open, chosen in a sheet;
    /// a test run gives it with `file:/path`.
    private func chooseFile(saving name: String?, then use: @escaping (URL) -> Void) {
        #if DEBUG
        if let path = DebugAutomation.takeChosenFile() {
            use(URL(filePath: path))
            return
        }
        #endif
        guard let window = view.window else { return }
        let panel: NSSavePanel
        if let name {
            panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.plainText]
        } else {
            let open = NSOpenPanel()
            open.allowsMultipleSelection = false
            open.canChooseDirectories = false
            panel = open
        }
        panel.directoryURL = remote == nil && archive == nil ? directory : nil
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { use(url) }
        }
    }

    private func copyToClipboard(_ lines: [String]) {
        guard !lines.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = AppDefaults.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Context menu

    /// Context menu of applications: a button on the bar that starts them.
    @objc private func addToButtonBar(_ sender: Any?) {
        let apps = selectedItems.map(\.url).filter(ToolbarApps.isApplication)
        (view.window?.windowController as? MainWindowController)?.addApplications(apps)
    }

    private func contextMenu(for items: [FileItem]) -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
            return item
        }
        if let first = items.first {
            add(String(localized: "Open"), #selector(openSelection(_:)), target: self)
            if items.count == 1, !first.isFolder, archive == nil {
                let openWith = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
                openWith.submenu = openWithMenu(for: first.url)
                menu.addItem(openWith)
            }
            add(Command.list.title, Command.list.selector)
            if archive == nil {
                add(String(localized: "Show in Finder"), #selector(revealInFinder(_:)), target: self)
            }
            if archive == nil, remote == nil, items.contains(where: { ToolbarApps.isApplication($0.url) }) {
                add(String(localized: "Add to Button Bar"), #selector(addToButtonBar(_:)), target: self)
            }
            menu.addItem(.separator())
            if archive == nil {
                add(String(localized: "edit.copy", defaultValue: "Copy"), #selector(copy(_:)))
                add(String(localized: "Cut"), #selector(cut(_:)))
            }
        }
        add(String(localized: "Paste"), #selector(paste(_:)))
        if !items.isEmpty {
            add(Command.copyFullNamesToClip.title, Command.copyFullNamesToClip.selector)
            menu.addItem(.separator())
            add(Command.renameOnly.title, Command.renameOnly.selector)
            // Holding Shift turns Delete into Delete Permanently.
            add(Command.delete.title, Command.delete.selector).keyEquivalentModifierMask = []
            let permanently = add(Command.deletePermanently.title, Command.deletePermanently.selector)
            permanently.keyEquivalentModifierMask = .shift
            permanently.isAlternate = true
            if archive == nil {
                menu.addItem(.separator())
                add(Command.packFiles.title, Command.packFiles.selector)
                if items.contains(where: { !$0.isDirectory && ArchiveReader.isArchive($0.name) }) {
                    add(Command.unpackFiles.title, Command.unpackFiles.selector)
                }
            }
        }
        // The files' Get Info windows, or the folder's on [..] and empty space.
        if archive == nil, remote == nil {
            menu.addItem(.separator())
            add(Command.properties.title, Command.properties.selector)
        }
        return menu
    }

    // MARK: - Drive buttons

    /// A drive button's context menu, as the Finder's for a volume.
    private func driveMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
            return item
        }
        let isHome = url.path == FileManager.default.homeDirectoryForCurrentUser.path
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeSupportsRenamingKey])
        let name = values?.volumeLocalizedName ?? url.lastPathComponent
        add(String(localized: "Open"), #selector(openDriveItem(_:)))
        add(String(localized: "Open in New Tab"), #selector(openDriveInNewTab(_:)))
        add(String(localized: "Open in Other Panel"), #selector(openDriveInOtherPanel(_:)))
        add(String(localized: "Show in Finder"), #selector(showDriveInFinder(_:)))
        if !isHome, Volume.isEjectable(url) {
            menu.addItem(.separator())
            add(String(localized: "Eject \u{201C}\(name)\u{201D}"), #selector(ejectDrive(_:)))
        }
        menu.addItem(.separator())
        add(Command.properties.title, #selector(showDriveInfo(_:)))
        if !isHome, values?.volumeSupportsRenaming == true {
            add(String(localized: "Rename \u{201C}\(name)\u{201D}…"), #selector(renameDrive(_:)))
        }
        add(Command.copyFullNamesToClip.title, #selector(copyDrivePath(_:)))
        return menu
    }

    @objc private func openDriveItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        focus()
        openDrive(url)
    }

    @objc private func openDriveInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        focus()
        openTab(url)
    }

    @objc private func openDriveInOtherPanel(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.filePanel(self, openDriveInOtherPanel: url)
    }

    @objc private func showDriveInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    @objc private func ejectDrive(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.filePanel(self, eject: url)
    }

    @objc private func showDriveInfo(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        showInfo([url])
    }

    @objc private func copyDrivePath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        copyToClipboard([url.path])
    }

    /// Renames a volume (its mount point follows; the panels go along, see
    /// `volumeWasRenamed`).
    @objc private func renameDrive(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let window = view.window else { return }
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
        Prompt.text(String(localized: "Rename \u{201C}\(name)\u{201D}"), message: String(localized: "New name:"),
                    initial: name, okTitle: String(localized: "Rename"), in: window) { newName in
            guard !newName.isEmpty, newName != name else { return }
            var values = URLResourceValues()
            values.volumeName = newName
            var volume = url
            do {
                try volume.setResourceValues(values)
            } catch {
                Prompt.error(String(localized: "Cannot rename \u{201C}\(name)\u{201D}"), error, in: window)
            }
        }
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let defaultApplication = NSWorkspace.shared.urlForApplication(toOpen: url)
        var applications = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApplication {
            applications.removeAll { $0 == defaultApplication }
            applications.insert(defaultApplication, at: 0)
        }
        for application in applications.prefix(25) {
            var title = FileManager.default.displayName(atPath: application.path)
            if title.hasSuffix(".app") {
                title = (title as NSString).deletingPathExtension
            }
            if application == defaultApplication {
                title = String(localized: "\(title) (default)")
            }
            let item = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = application
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if application == defaultApplication && applications.count > 1 {
                menu.addItem(.separator())
            }
        }
        return menu
    }

    @objc private func openSelection(_ sender: Any?) {
        fileList(listView, openItemAt: listView.cursor)
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedItems.map(\.url), withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
    }

    /// Alt+Enter: the Finder's Get Info windows of the marked files, the file under the
    /// cursor, or the folder shown (through the Finder's "Show Info" service).
    @objc(cm_Properties:)
    func properties(_ sender: Any?) {
        guard archive == nil, remote == nil else {
            NSSound.beep()
            return
        }
        showInfo(selectedItems.isEmpty ? [directory] : selectedItems.map(\.url))
    }

    private func showInfo(_ urls: [URL]) {
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ru.themmag.OriCmd.ShowInfo"))
        pasteboard.declareTypes([filenames], owner: nil)
        pasteboard.setPropertyList(urls.map(\.path), forType: filenames)
        if !NSPerformService("Finder/Show Info", pasteboard) {
            NSSound.beep()
        }
    }

    /// Alt+Shift+Enter: calculates the sizes of all folders in the panel.
    @objc(cm_CountDirContent:)
    func countDirContent(_ sender: Any?) {
        calculateSizes(of: listView.items.filter { $0.isFolder && !$0.isParent })
    }

    /// Calculates folder sizes in the background and shows them as they arrive.
    private func calculateSizes(of folders: [FileItem]) {
        guard archive == nil, remote == nil else { return }
        let directory = directory
        for folder in folders {
            let url = folder.url
            Task {
                let size = await Self.folderSize(url)
                guard self.directory == directory else { return }
                listView.folderSizes[folder.name] = size
                updateStatus()
            }
        }
    }

    @concurrent
    private nonisolated static func folderSize(_ url: URL) async -> Int64 {
        TransferEngine.totalSize(of: url)
    }

    /// Shift+F4: asks for a file name, creates the file if needed and edits it.
    @objc(cm_EditNewFile:)
    func editNewFile(_ sender: Any?) {
        guard !refuseInsideArchive(), let window = view.window else { return }
        let initial = listView.currentItem.flatMap { $0.isFolder ? nil : $0.name } ?? "new.txt"
        Prompt.text(String(localized: "Edit new file"), message: String(localized: "File name:"),
                    initial: initial, okTitle: String(localized: "Edit"), in: window) { [weak self] name in
            guard let self, !name.isEmpty, !name.contains("/") else { return }
            let url = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    Prompt.error(String(localized: "Cannot create \u{201C}\(name)\u{201D}"),
                                 CocoaError(.fileWriteUnknown), in: window)
                    return
                }
            }
            load(directory, selecting: name)
            openInEditor(url)
        }
    }

    private func openInEditor(_ url: URL) {
        if FileAssociations.perform(.edit, on: url, window: view.window) {
            return
        }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shift+F5: copies the entry under the cursor within the same folder, under a new name.
    @objc(cm_CopySamepanel:)
    func copySamePanel(_ sender: Any?) {
        guard !refuseInsideArchive(), let item = listView.currentItem, !item.isParent,
              let window = view.window else {
            NSSound.beep()
            return
        }
        let selection = NSRange(location: 0, length: (item.isFolder ? item.name : item.baseName).utf16.count)
        Prompt.text(String(localized: "copy.title", defaultValue: "Copy"),
                    message: String(localized: "Copy \u{201C}\(item.name)\u{201D} as:"),
                    initial: item.name, selection: selection,
                    okTitle: String(localized: "copy.button", defaultValue: "Copy"), in: window) { [weak self] name in
            guard let self, !name.isEmpty, name != item.name, !name.contains("/") else { return }
            var job = TransferJob(kind: .copy, sources: [item.url], destination: directory, newName: name)
            job.options.skipsDSStore = Settings.copySkipsDSStore
            Task {
                _ = await TransferController.run(job, in: window)
                self.load(self.directory, selecting: name)
            }
        }
    }

    /// F3: opens the file under the cursor in the Lister window (or its associated viewer).
    @objc(cm_List:)
    func list(_ sender: Any?) {
        guard let item = listView.currentItem, !item.isParent, !item.isFolder else {
            NSSound.beep()
            return
        }
        if archive != nil || remote != nil {
            let title = remote.map { $0.displayPath + "/" + item.name }
                ?? archive.map { $0.displayPath + "/" + item.name }
            Task {
                let url = remote != nil ? await downloadToTemporaryFolder(item) : await extractToTemporaryFolder(item)
                if let url, !FileAssociations.perform(.view, on: url, window: view.window) {
                    ListerWindowController.show(url, title: title)
                }
            }
            return
        }
        if FileAssociations.perform(.view, on: item.url, window: view.window) {
            return
        }
        let files = listView.items.filter { !$0.isParent && !$0.isFolder }.map(\.url)
        ListerWindowController.show(item.url, siblings: files)
    }

    /// F4: opens the file under the cursor in its associated editor or the default text editor.
    @objc(cm_Edit:)
    func edit(_ sender: Any?) {
        guard !refuseInsideArchive() else { return }
        guard let item = listView.currentItem, !item.isParent, !item.isFolder else {
            NSSound.beep()
            return
        }
        openInEditor(item.url)
    }

    /// F7: asks for a name (prefilled with the entry under the cursor, as TC does).
    @objc(cm_MkDir:)
    func mkDir(_ sender: Any?) {
        guard remote != nil || !refuseReadOnlyArchive() else { return }
        guard let window = view.window else { return }
        let initial = listView.currentItem.flatMap { $0.isParent ? nil : $0.name } ?? ""
        Prompt.text(String(localized: "New folder"), message: String(localized: "Folder name (use / for nested folders):"),
                    initial: initial, okTitle: String(localized: "Create"), in: window) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let topLevel = name.split(separator: "/").first.map(String.init) ?? name
            if let remote {
                runOnServer(selecting: topLevel) { try await remote.fileSystem.makeDirectory(remote.path(of: name)) }
                return
            }
            if let archive {
                applyArchiveEdit(.makeFolder(archive.path(of: name)), selecting: topLevel)
                return
            }
            do {
                _ = try FileOperations.createDirectory(named: name, in: directory)
                load(directory, selecting: topLevel)
            } catch {
                Prompt.error(String(localized: "Cannot create folder \u{201C}\(name)\u{201D}"), error, in: view.window)
            }
        }
    }

    /// F8 / Del / ⌘⌫: moves the selection to the Trash after confirmation.
    @objc(cm_Delete:)
    func delete(_ sender: Any?) {
        guard !refuseReadOnlyArchive() else { return }
        confirmDelete(permanently: false)
    }

    /// ⇧F8 / ⇧Del: deletes the selection permanently after confirmation.
    @objc(cm_DeletePermanently:)
    func deletePermanently(_ sender: Any?) {
        guard !refuseReadOnlyArchive() else { return }
        confirmDelete(permanently: true)
    }

    /// ⇧F6: renames the entry under the cursor in place.
    @objc(cm_RenameOnly:)
    func renameOnly(_ sender: Any?) {
        if listView.isRenaming {
            listView.selectNextPartOfName()
            return
        }
        guard !refuseReadOnlyArchive() else { return }
        guard let item = listView.currentItem, !item.isParent else {
            NSSound.beep()
            return
        }
        focus()
        listView.beginRenaming()
    }

    private func confirmDelete(permanently: Bool) {
        let items = selectedItems
        guard !items.isEmpty, let window = view.window else {
            NSSound.beep()
            return
        }
        let what = items.count == 1
            ? String(localized: "\u{201C}\(items[0].name)\u{201D}")
            : String(localized: "the selected \(items.count) files/folders")
        if let remote {
            Prompt.confirm(String(localized: "Delete \(what) from the server?"),
                           message: String(localized: "This cannot be undone."),
                           okTitle: String(localized: "Delete"), destructive: true, in: window) { [weak self] in
                self?.runOnServer(selecting: nil) { try await remote.fileSystem.delete(items, in: remote.path) }
            }
        } else if let archive {
            Prompt.confirm(String(localized: "Delete \(what) from the archive?"),
                           message: String(localized: "This cannot be undone."),
                           okTitle: String(localized: "Delete"), destructive: true, in: window) { [weak self] in
                self?.applyArchiveEdit(.delete(items.map { archive.path(of: $0.name) }))
            }
        } else if permanently {
            Prompt.confirm(String(localized: "Do you really want to permanently delete \(what)?"),
                           message: String(localized: "Nothing goes to the Trash: this cannot be undone."),
                           okTitle: String(localized: "Delete"), destructive: true, in: window) { [weak self] in
                self?.performDelete(items.map(\.url), permanently: true)
            }
        } else if !Settings.confirmsMoveToTrash {
            performDelete(items.map(\.url), permanently: false)
        } else {
            Prompt.confirm(String(localized: "Do you really want to move \(what) to the Trash?"),
                           okTitle: String(localized: "Move to Trash"), in: window) { [weak self] in
                self?.performDelete(items.map(\.url), permanently: false)
            }
        }
    }

    private func performDelete(_ urls: [URL], permanently: Bool) {
        Task {
            do {
                if permanently {
                    try await FileOperations.deletePermanently(urls)
                } else {
                    try await FileOperations.moveToTrash(urls)
                }
            } catch {
                Prompt.error(String(localized: "Cannot delete"), error, in: view.window)
            }
            // The cursor stays at the same row, i.e. on the next remaining entry.
            reread()
        }
    }

    @objc(cm_SrcByName:)
    func sortByName(_ sender: Any?) {
        sort(by: .name)
    }

    @objc(cm_SrcByExt:)
    func sortByExt(_ sender: Any?) {
        sort(by: .ext)
    }

    @objc(cm_SrcByDateTime:)
    func sortByDateTime(_ sender: Any?) {
        sort(by: .date)
    }

    @objc(cm_SrcBySize:)
    func sortBySize(_ sender: Any?) {
        sort(by: .size)
    }

    @objc(cm_SrcNegOrder:)
    func reverseOrder(_ sender: Any?) {
        sortOrder.ascending.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(chooseColumnSetFromMenu(_:)):
            menuItem.state = (menuItem.representedObject as? String) == columnSetShown ? .on : .off
            return true
        case #selector(copy(_:)), #selector(cut(_:)):
            return archive == nil && !selectedItems.isEmpty
        case #selector(paste(_:)), #selector(moveItemsHere(_:)):
            return !clipboardFiles.isEmpty || PromisedFiles.areOffered(on: AppDefaults.pasteboard)
        default:
            break
        }
        guard let action = menuItem.action, let command = Command(selector: action) else { return true }
        let sortColumn: SortColumn? = switch command {
        case .sortByName: .name
        case .sortByExt: .ext
        case .sortByDateTime: .date
        case .sortBySize: .size
        default: nil
        }
        if let sortColumn {
            menuItem.state = sortOrder.column == sortColumn && !sortOrder.isUnsorted ? .on : .off
        } else if command == .unsorted {
            menuItem.state = sortOrder.isUnsorted ? .on : .off
        } else if command == .reverseOrder {
            menuItem.state = sortOrder.ascending ? .off : .on
        } else if command == .goToParent {
            return directory.path != "/"
        } else if command == .properties {
            return archive == nil && remote == nil
        } else if command == .branchView {
            menuItem.state = isBranchView ? .on : .off
        } else if command == .srcAllFiles || command == .srcUserSpec {
            menuItem.state = (filterMask == nil && (command == .srcUserSpec || onlyNames == nil)) == (command == .srcAllFiles)
                ? .on : .off
        } else if command == .showOnlySelected {
            menuItem.state = onlyNames == nil ? .off : .on
        } else if command == .srcShort || command == .srcLong || command == .srcThumbs {
            let mode: FileListView.ViewMode = command == .srcShort ? .brief : (command == .srcLong ? .full : .thumbnails)
            menuItem.state = viewMode == mode ? .on : .off
        } else if [.closeCurrentTab, .switchToNextTab, .switchToPreviousTab].contains(command) {
            return tabs.count > 1
        } else if command == .serverTerminal {
            menuItem.state = panelView.isTerminalVisible ? .on : .off
            return remote?.fileSystem is SFTPFileSystem
        } else if command == .terminalChangeDir {
            return remote != nil && panelView.terminalPane.isRunning
        }
        return true
    }
}

// MARK: - Quick search

extension FilePanelController: NSTextFieldDelegate {
    /// Ctrl+S: shows the box as a quick filter (Enter keeps the filter, Esc removes it).
    @objc(cm_QuickFilter:)
    func quickFilterCommand(_ sender: Any?) {
        beginQuickSearch(quickFilter ?? "", filtering: true)
    }

    func beginQuickSearch(_ text: String, filtering: Bool = false) {
        quickSearchFilters = filtering
        let field = panelView.quickSearchField
        field.placeholderString = filtering ? String(localized: "Quick filter") : String(localized: "Quick search")
        field.stringValue = text
        field.isHidden = false
        panelView.statusLabel.isHidden = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if !filtering {
            jumpToMatch(from: 0, forward: true)
        }
    }

    private func endQuickSearch(openingItem: Bool) {
        let field = panelView.quickSearchField
        guard !field.isHidden else { return }
        field.isHidden = true
        panelView.statusLabel.isHidden = false
        focus()
        if openingItem {
            fileList(listView, openItemAt: listView.cursor)
        }
    }

    /// Names starting with the typed text match; a leading "*" matches anywhere.
    private func matches(_ item: FileItem, _ text: String) -> Bool {
        guard !item.isParent, !text.isEmpty else { return false }
        if text.hasPrefix("*") {
            let rest = String(text.dropFirst())
            return rest.isEmpty || item.name.localizedCaseInsensitiveContains(rest)
        }
        return item.name.range(of: text, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
    }

    private func jumpToMatch(from start: Int, forward: Bool) {
        let text = panelView.quickSearchField.stringValue
        let items = listView.items
        guard !items.isEmpty else { return }
        for step in 0..<items.count {
            let index = forward
                ? (start + step) % items.count
                : (start - step + items.count) % items.count
            if matches(items[index], text) {
                listView.moveCursor(to: index)
                return
            }
        }
        NSSound.beep()
    }

    func controlTextDidChange(_ notification: Notification) {
        if quickSearchFilters {
            let text = panelView.quickSearchField.stringValue
            quickFilter = text.isEmpty ? nil : text
        } else {
            jumpToMatch(from: listView.cursor, forward: true)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if quickSearchFilters {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                listView.moveCursor(to: listView.cursor + 1)
            case #selector(NSResponder.moveUp(_:)):
                listView.moveCursor(to: listView.cursor - 1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                endQuickSearch(openingItem: false)
            case #selector(NSResponder.cancelOperation(_:)):
                quickFilter = nil
                endQuickSearch(openingItem: false)
            default:
                return false
            }
            return true
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            jumpToMatch(from: listView.cursor + 1, forward: true)
        case #selector(NSResponder.moveUp(_:)):
            jumpToMatch(from: listView.cursor - 1 + listView.items.count, forward: false)
        case #selector(NSResponder.insertNewline(_:)):
            endQuickSearch(openingItem: true)
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)):
            endQuickSearch(openingItem: false)
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endQuickSearch(openingItem: false)
    }
}

extension FilePanelController: FileListViewDelegate {
    func fileListDidBecomeActive(_ list: FileListView) {
        delegate?.filePanelDidBecomeActive(self)
        if terminalWasFocused {
            terminalWasFocused = false
            if remote != nil { reread() }
        }
    }

    func fileList(_ list: FileListView, openItemAt index: Int) {
        guard list.items.indices.contains(index) else { return }
        open(list.items[index], enteringPackages: false)
    }

    func fileList(_ list: FileListView, enterItemAt index: Int) {
        guard list.items.indices.contains(index) else { return }
        open(list.items[index], enteringPackages: true)
    }

    func fileListGoToParent(_ list: FileListView) {
        goToParent()
    }

    func fileListSwitchPanel(_ list: FileListView) {
        delegate?.filePanelSwitchPanel(self)
    }

    func fileList(_ list: FileListView, rename item: FileItem, to newName: String) {
        guard newName != item.name else { return }
        if let remote {
            // Servers would replace an existing entry of that name.
            if listView.items.contains(where: { $0.name == newName && !$0.isParent }) {
                Prompt.error(String(localized: "Cannot rename \u{201C}\(item.name)\u{201D}"),
                             RemoteError(String(localized: "\u{201C}\(newName)\u{201D} already exists.")), in: view.window)
                return
            }
            runOnServer(selecting: newName) {
                try await remote.fileSystem.rename(remote.path(of: item.name), to: remote.path(of: newName))
            }
            return
        }
        if let archive {
            applyArchiveEdit(.rename(archive.path(of: item.name), to: newName), selecting: newName)
            return
        }
        // Branch view and search results show "sub/file.txt": the folder part stays.
        var newName = newName
        if let slash = item.name.lastIndex(of: "/") {
            let folderPart = String(item.name[...slash])
            if newName.hasPrefix(folderPart) { newName.removeFirst(folderPart.count) }
        }
        do {
            let url = try FileOperations.rename(item.url, to: newName)
            if let results = searchResults {
                let urls = results.urls.map { $0 == item.url ? url : $0 }
                let shown = (item.name as NSString).deletingLastPathComponent
                showSearchResults(urls, root: directory, title: results.title,
                                  selecting: shown.isEmpty ? newName : shown + "/" + newName)
                return
            }
            load(directory, selecting: url.lastPathComponent)
        } catch {
            Prompt.error(String(localized: "Cannot rename \u{201C}\(item.name)\u{201D}"), error, in: view.window)
        }
    }

    func fileListMarksDidChange(_ list: FileListView) {
        updateStatus()
    }

    func fileListCursorDidMove(_ list: FileListView) {
        delegate?.filePanelCursorDidMove(self)
    }

    func fileList(_ list: FileListView, contextMenuFor items: [FileItem]) -> NSMenu? {
        contextMenu(for: items)
    }

    func fileListCanDragItems(_ list: FileListView) -> Bool {
        archive == nil && remote == nil
    }

    func fileList(_ list: FileListView, drop urls: [URL], into folder: FileItem?, moving: Bool) -> Bool {
        // Files dragged from another program may not be written yet (see FileCoordination).
        whenWritten(urls) { [weak self] in self?.drop(urls, into: folder, moving: moving) }
        return true
    }

    /// Whether files dropped onto `folder` would go into a read-only archive; says so.
    private func refusesDrop(into folder: FileItem?) -> Bool {
        guard let archive else { return false }
        // [..] at an archive's root is the folder beside it; inside an archive inside
        // an archive, it is the outer archive.
        if archive.outer == nil, archive.folder.isEmpty, folder?.isParent == true { return false }
        return refuseReadOnlyArchive()
    }

    private func drop(_ urls: [URL], into folder: FileItem?, moving: Bool) {
        guard !refusesDrop(into: folder) else { return }
        if let remote {
            let target = folder.map { $0.isParent ? RemotePath.parent(of: remote.path) : remote.path(of: $0.name) }
            upload(urls, to: target, moving: moving)
            return
        }
        if let archive, !(folder?.isParent == true && archive.folder.isEmpty) {
            let target: String
            if let folder {
                target = folder.isParent ? (archive.folder as NSString).deletingLastPathComponent : archive.path(of: folder.name)
            } else {
                target = archive.folder
            }
            applyArchiveEdit(.add(urls, folder: target), selecting: urls.first?.lastPathComponent) { succeeded in
                guard succeeded, moving else { return }
                Task { try? await FileOperations.deletePermanently(urls) }
            }
            return
        }
        let destination = archive != nil ? directory : (folder?.url ?? directory)
        transfer(urls, to: destination, moving: moving)
    }

    /// Dragged files another program promised: it writes them into a private folder on
    /// this folder's volume, then they go where they were dropped.
    func fileList(_ list: FileListView, dropPromises receivers: [NSFilePromiseReceiver], into folder: FileItem?) -> Bool {
        // Refused before receiving, so no received files are left behind.
        guard let window = view.window, !refusesDrop(into: folder) else { return false }
        let base = remote == nil && archive == nil ? directory : FileManager.default.temporaryDirectory
        guard let privateFolder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                                appropriateFor: base, create: true) else { return false }
        let received = OSAllocatedUnfairLock(initialState: [URL]())
        let group = DispatchGroup()
        let queue = OperationQueue()
        for receiver in receivers {
            // One wait per promise: its file names are known only once receiving began,
            // and the reader is called once per file.
            group.enter()
            nonisolated(unsafe) let receiver = receiver
            let calls = OSAllocatedUnfairLock(initialState: (count: 0, done: false))
            receiver.receivePromisedFiles(atDestination: privateFolder, options: [:], operationQueue: queue) { url, error in
                if error == nil { received.withLock { $0.append(url) } }
                let finished = calls.withLock { state -> Bool in
                    state.count += 1
                    guard !state.done, state.count >= max(receiver.fileNames.count, 1) else { return false }
                    state.done = true
                    return true
                }
                if finished { group.leave() }
            }
        }
        var cancelled = false
        let closeProgress = Prompt.progress(String(localized: "Receiving Files…"),
                                            in: window) { cancelled = true }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                closeProgress()
                let files = received.withLock { $0 }
                guard let self, !cancelled, !files.isEmpty else {
                    try? FileManager.default.removeItem(at: privateFolder)
                    return
                }
                _ = self.fileList(list, drop: files, into: folder, moving: true)
            }
        }
        return true
    }

    func fileList(_ list: FileListView, calculateSizeOf item: FileItem) {
        calculateSizes(of: [item])
    }

    func fileList(_ list: FileListView, beginQuickSearchWith text: String) {
        beginQuickSearch(text)
    }

    func fileList(_ list: FileListView, interceptKey event: NSEvent) -> Bool {
        delegate?.filePanel(self, interceptKey: event) ?? false
    }

    func fileList(_ list: FileListView, markGroup mark: Bool) {
        askForMask(marking: mark)
    }
}
