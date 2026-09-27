import AppKit

@MainActor
protocol FilePanelControllerDelegate: AnyObject {
    func filePanelDidBecomeActive(_ panel: FilePanelController)
    func filePanelSwitchPanel(_ panel: FilePanelController)
    func filePanelDidChangeDirectory(_ panel: FilePanelController)
    func filePanelCursorDidMove(_ panel: FilePanelController)
    func filePanel(_ panel: FilePanelController, interceptKey event: NSEvent) -> Bool
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

    /// Where the panel is inside an archive, while browsing one.
    struct ArchiveLocation {
        let url: URL
        var folder: String
        var entries: [ArchiveEntry]

        var displayPath: String { folder.isEmpty ? url.path : url.path + "/" + folder }

        /// Archive paths of entries shown in the current folder.
        func path(of name: String) -> String {
            folder.isEmpty ? name : folder + "/" + name
        }
    }

    /// Set while the panel shows the inside of an archive (read-only).
    private(set) var archive: ArchiveLocation?
    private var lastMask = "*.*"
    private var watcher: DirectoryWatcher?

    struct HistoryEntry {
        let directory: URL
        let selectedName: String?
    }

    /// A folder tab: everything that differs between tabs of one panel.
    struct Tab {
        var directory: URL
        var selectedName: String?
        var sortOrder: SortOrder
        var backHistory: [HistoryEntry] = []
        var forwardHistory: [HistoryEntry] = []

        var title: String {
            directory.path == "/" ? "/" : directory.lastPathComponent
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
            refreshList(selecting: listView.currentItem?.name)
        }
    }

    var showsHidden = false {
        didSet { refreshList(selecting: listView.currentItem?.name) }
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
    init(tabDirectories: [URL], activeTab: Int = 0) {
        let directories = tabDirectories.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : tabDirectories
        let active = min(max(activeTab, 0), directories.count - 1)
        directory = directories[active]
        tabs = directories.map { Tab(directory: $0, sortOrder: SortOrder()) }
        activeTabIndex = active
        super.init(nibName: nil, bundle: nil)

        listView.delegate = self
        panelView.headerView.sortOrder = sortOrder
        panelView.headerView.onColumnClicked = { [weak self] column in self?.sort(by: column) }
        panelView.pathBar.onClick = { [weak self] in self?.focus() }
        panelView.onGoToRoot = { [weak self] in self?.goToRoot() }
        panelView.onGoToParent = { [weak self] in self?.goToParent() }
        panelView.onVolumeSelected = { [weak self] volume in self?.load(volume.url) }
        panelView.tabBar.onSelect = { [weak self] index in self?.selectTab(index) }
        panelView.tabBar.onClose = { [weak self] index in self?.closeTab(index) }
        panelView.quickSearchField.delegate = self

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
        listView.settingsDidChange()
        panelView.pathBar.needsDisplay = true
        panelView.headerView.needsDisplay = true
    }

    func focus() {
        panelView.window?.makeFirstResponder(listView)
    }

    // MARK: - Navigation

    /// Reads `directory` and shows it, placing the cursor on `name` if given.
    func load(_ directory: URL, selecting name: String? = nil, recordingHistory: Bool = true) {
        let directory = directory.standardizedFileURL
        let entries: [FileItem]
        do {
            entries = try DirectoryListing.items(in: directory)
        } catch {
            present(error, reading: directory)
            return
        }
        if archive != nil {
            archive = nil
            listView.setMarked([])
        }
        let isNewDirectory = directory != self.directory
        if isNewDirectory {
            if recordingHistory {
                backHistory.append(HistoryEntry(directory: self.directory, selectedName: listView.currentItem?.name))
                backHistory = Array(backHistory.suffix(Self.historyLimit))
                forwardHistory.removeAll()
            }
            listView.setMarked([])
        }
        self.directory = directory
        self.entries = entries
        if isNewDirectory || watcher == nil {
            watcher = DirectoryWatcher(url: directory) { [weak self] in self?.reread() }
        }
        panelView.show(directory: directory, volumes: Volume.mounted())
        refreshList(selecting: name, fallback: isNewDirectory ? 0 : listView.cursor)
        if tabs[activeTabIndex].directory != directory {
            tabs[activeTabIndex].directory = directory
            updateTabBar()
        }
        delegate?.filePanelDidChangeDirectory(self)
    }

    // MARK: - Archives

    /// Shows the contents of an archive as a folder (Enter / Ctrl+PgDn on it).
    func openArchive(_ url: URL) {
        do {
            let entries = try ArchiveReader.entries(of: url)
            listView.setMarked([])
            archive = ArchiveLocation(url: url, folder: "", entries: entries)
            showArchiveFolder(selecting: nil)
        } catch {
            Prompt.error(String(localized: "Cannot open archive \u{201C}\(url.lastPathComponent)\u{201D}"), error,
                         in: view.window)
        }
    }

    private func reopenArchive(_ location: ArchiveLocation, selecting name: String? = nil) {
        guard let entries = try? ArchiveReader.entries(of: location.url) else {
            load(directory)
            return
        }
        archive?.entries = entries
        showArchiveFolder(selecting: name ?? listView.currentItem?.name)
    }

    /// Changes the archive shown in this panel (with a progress sheet), then
    /// shows its new contents. `completion` receives whether it succeeded.
    func applyArchiveEdit(_ edit: ArchiveEditor.Edit, selecting name: String? = nil,
                          completion: ((Bool) -> Void)? = nil) {
        guard let archive, let window = view.window else { return }
        let url = archive.url
        Task {
            let done = await TransferController(title: String(localized: "Updating archive"),
                                                failureTitle: String(localized: "Cannot update archive"), window: window)
                .run(source: url.path, target: url.path) { progress, _ in
                    try await ArchiveEditor.apply(edit, to: url, progress: progress)
                    return [url]
                }
            if let current = self.archive, current.url == url {
                reopenArchive(current, selecting: name)
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
        for entry in archive.entries where entry.path.hasPrefix(prefix) && entry.path.count > prefix.count {
            let rest = entry.path.dropFirst(prefix.count)
            let childName = String(rest.prefix { $0 != "/" })
            let isNested = rest.contains("/")
            if isNested && children[childName] != nil { continue }
            let isFolder = isNested || entry.isDirectory
            children[childName] = FileItem(
                name: childName, url: archive.url.appending(path: prefix + childName),
                isDirectory: isFolder, isPackage: false, isSymlink: false, isHidden: childName.hasPrefix("."),
                size: isFolder ? 0 : entry.size, modified: entry.modified,
                mode: isNested ? 0o755 : entry.mode
            )
        }
        entries = Array(children.values)
        panelView.show(directory: directory, volumes: Volume.mounted())
        panelView.pathBar.path = archive.displayPath
        refreshList(selecting: name, fallback: 0)
        delegate?.filePanelDidChangeDirectory(self)
    }

    private func openInArchive(_ item: FileItem) {
        guard let archive else { return }
        if item.isParent {
            archiveGoUp()
        } else if item.isDirectory {
            self.archive?.folder = archive.path(of: item.name)
            showArchiveFolder(selecting: nil)
        } else {
            Task {
                if let url = await extractToTemporaryFolder(item) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Up one folder inside the archive, or out of it at its root.
    private func archiveGoUp() {
        guard let archive else { return }
        if archive.folder.isEmpty {
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
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await ArchiveReader.extract(archive.url, paths: [archive.path(of: item.name)], base: archive.folder,
                                            to: folder, progress: TransferProgress())
            return folder.appending(path: item.name)
        } catch {
            Prompt.error(String(localized: "Cannot unpack \u{201C}\(item.name)\u{201D}"), error, in: view.window)
            return nil
        }
    }

    /// Refuses changes inside archives that cannot be written (rar, iso, …).
    private func refuseReadOnlyArchive() -> Bool {
        guard let archive, !ArchiveEditor.isWritable(archive.url) else { return false }
        Prompt.info(String(localized: "This archive is read-only"),
                    message: String(localized: "Only zip, tar, tar.gz, tar.bz2, tar.xz and 7z archives can be changed."),
                    in: view.window)
        return true
    }

    /// Refuses operations that are never available inside archives.
    private func refuseInsideArchive() -> Bool {
        guard archive != nil else { return false }
        Prompt.info(String(localized: "Not supported inside archives"),
                    message: String(localized: "Unpack the files first (F5), or use Alt+F5 to create a new archive."),
                    in: view.window)
        return true
    }

    // MARK: - Tabs

    /// Tab directories and the active tab, for saving the panel between launches.
    var tabState: (directories: [String], active: Int) {
        (tabs.map(\.directory.path), activeTabIndex)
    }

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

    /// The last tab is never closed, as in Total Commander.
    func closeTab(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else {
            NSSound.beep()
            return
        }
        tabs.remove(at: index)
        if index == activeTabIndex {
            activateTab(at: min(index, tabs.count - 1))
        } else {
            if index < activeTabIndex { activeTabIndex -= 1 }
            updateTabBar()
            delegate?.filePanelDidChangeDirectory(self)
        }
    }

    private func currentTab() -> Tab {
        Tab(directory: directory, selectedName: listView.currentItem?.name, sortOrder: sortOrder,
            backHistory: backHistory, forwardHistory: forwardHistory)
    }

    private func activateTab(at index: Int) {
        activeTabIndex = index
        let tab = tabs[index]
        backHistory = tab.backHistory
        forwardHistory = tab.forwardHistory
        if sortOrder != tab.sortOrder {
            sortOrder = tab.sortOrder
        }
        load(tab.directory, selecting: tab.selectedName, recordingHistory: false)
        updateTabBar()
        delegate?.filePanelDidChangeDirectory(self)
    }

    private func updateTabBar() {
        panelView.setTabs(tabs.map(\.title), selected: activeTabIndex, visible: tabs.count > 1 || alwaysShowsTabBar)
    }

    func goBack() {
        guard let entry = backHistory.popLast() else {
            NSSound.beep()
            return
        }
        forwardHistory.append(HistoryEntry(directory: directory, selectedName: listView.currentItem?.name))
        load(entry.directory, selecting: entry.selectedName, recordingHistory: false)
    }

    func goForward() {
        guard let entry = forwardHistory.popLast() else {
            NSSound.beep()
            return
        }
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
        if let archive {
            reopenArchive(archive)
            return
        }
        var directory = self.directory
        while !FileManager.default.fileExists(atPath: directory.path) && directory.path != "/" {
            directory = directory.deletingLastPathComponent()
        }
        load(directory, selecting: listView.currentItem?.name)
    }

    /// Mounted volumes changed: refresh the volume list, leave a vanished volume.
    func volumesDidChange() {
        if FileManager.default.fileExists(atPath: directory.path) {
            panelView.show(directory: directory, volumes: Volume.mounted())
        } else {
            load(FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    func goToParent() {
        if archive != nil {
            archiveGoUp()
            return
        }
        guard directory.path != "/" else { return }
        load(directory.deletingLastPathComponent(), selecting: directory.lastPathComponent)
    }

    func goToRoot() {
        if archive != nil {
            archive?.folder = ""
            showArchiveFolder(selecting: nil)
            return
        }
        let root = Volume.containing(directory, in: Volume.mounted())?.url ?? URL(filePath: "/")
        load(root)
    }

    func sort(by column: SortColumn) {
        if sortOrder.column == column {
            sortOrder.ascending.toggle()
        } else {
            sortOrder = SortOrder(column: column, ascending: true)
        }
    }

    private func refreshList(selecting name: String?, fallback: Int = 0) {
        var items = showsHidden ? entries : entries.filter { !$0.isHidden }
        items = sortOrder.sorted(items)
        if archive != nil || directory.path != "/" {
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

        func kilobytes(_ files: [FileItem]) -> String {
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            return ((bytes + 1023) / 1024).formatted(.number.grouping(.automatic))
        }
        let markedSize = kilobytes(markedFiles)
        let totalSize = kilobytes(files)
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
        if archive != nil {
            openInArchive(item)
        } else if item.isParent {
            goToParent()
        } else if !item.isDirectory && ArchiveReader.isArchive(item.name) {
            openArchive(item.url)
        } else if item.isFolder || (enteringPackages && item.isDirectory) {
            load(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
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

    /// Ctrl+Up: opens the folder under the cursor in a new tab.
    @objc(cm_OpenDirInNewTab:)
    func openDirInNewTab(_ sender: Any?) {
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
        let bar = panelView.pathBar
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bar.bounds.maxY), in: bar)
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
        MultiRenameWindowController.show(for: items) { [weak self] in self?.reread() }
    }

    /// F3: opens the file under the cursor in the Lister window.
    @objc(cm_List:)
    func list(_ sender: Any?) {
        guard let item = listView.currentItem, !item.isParent, !item.isFolder else {
            NSSound.beep()
            return
        }
        if archive != nil {
            Task {
                if let url = await extractToTemporaryFolder(item) {
                    ListerWindowController.show(url)
                }
            }
            return
        }
        ListerWindowController.show(item.url)
    }

    /// F4: opens the file under the cursor in the default text editor.
    @objc(cm_Edit:)
    func edit(_ sender: Any?) {
        guard !refuseInsideArchive() else { return }
        guard let item = listView.currentItem, !item.isParent, !item.isFolder else {
            NSSound.beep()
            return
        }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([item.url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// F7: asks for a name (prefilled with the entry under the cursor, as TC does).
    @objc(cm_MkDir:)
    func mkDir(_ sender: Any?) {
        guard !refuseReadOnlyArchive() else { return }
        guard let window = view.window else { return }
        let initial = listView.currentItem.flatMap { $0.isParent ? nil : $0.name } ?? ""
        Prompt.text(String(localized: "New folder"), message: String(localized: "Folder name (use / for nested folders):"),
                    initial: initial, okTitle: String(localized: "Create"), in: window) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let topLevel = name.split(separator: "/").first.map(String.init) ?? name
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
        if let archive {
            Prompt.confirm(String(localized: "Delete \(what) from the archive?"),
                           message: String(localized: "This cannot be undone."),
                           okTitle: String(localized: "Delete"), destructive: true, in: window) { [weak self] in
                self?.applyArchiveEdit(.delete(items.map { archive.path(of: $0.name) }))
            }
        } else if permanently {
            Prompt.confirm(String(localized: "Do you really want to permanently delete \(what)?"),
                           message: String(localized: "This cannot be undone."),
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
        guard let action = menuItem.action, let command = Command(selector: action) else { return true }
        let sortColumn: SortColumn? = switch command {
        case .sortByName: .name
        case .sortByExt: .ext
        case .sortByDateTime: .date
        case .sortBySize: .size
        default: nil
        }
        if let sortColumn {
            menuItem.state = sortOrder.column == sortColumn ? .on : .off
        } else if command == .reverseOrder {
            menuItem.state = sortOrder.ascending ? .off : .on
        } else if command == .goToParent {
            return directory.path != "/"
        } else if command == .srcShort || command == .srcLong {
            menuItem.state = (viewMode == .brief) == (command == .srcShort) ? .on : .off
        } else if [.closeCurrentTab, .switchToNextTab, .switchToPreviousTab].contains(command) {
            return tabs.count > 1
        }
        return true
    }
}

// MARK: - Quick search

extension FilePanelController: NSTextFieldDelegate {
    func beginQuickSearch(_ text: String) {
        let field = panelView.quickSearchField
        field.stringValue = text
        field.isHidden = false
        panelView.statusLabel.isHidden = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        jumpToMatch(from: 0, forward: true)
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
        jumpToMatch(from: listView.cursor, forward: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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
        if let archive {
            applyArchiveEdit(.rename(archive.path(of: item.name), to: newName), selecting: newName)
            return
        }
        do {
            let url = try FileOperations.rename(item.url, to: newName)
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
