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

    /// Ctrl+B: lists all files of the folder and its subfolders, with relative names.
    private(set) var isBranchView = false

    /// Show → Filter: only files matching this mask are listed (folders always are).
    private var filterMask: String? {
        didSet {
            panelView.pathBar.mask = filterMask ?? "*.*"
            refreshList(selecting: listView.currentItem?.name)
        }
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
        panelView.driveBar.onSelect = { [weak self] url in self?.load(url) }
        panelView.setDriveBarVisible(Settings.showsDriveButtons)
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
        panelView.setDriveBarVisible(Settings.showsDriveButtons)
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
        if directory != self.directory {
            isBranchView = false
        }
        var entries: [FileItem]
        do {
            entries = try DirectoryListing.items(in: directory)
        } catch {
            present(error, reading: directory)
            return
        }
        if isBranchView {
            entries = DirectoryListing.branchItems(in: directory, includingHidden: showsHidden)
        }
        if archive != nil {
            archive = nil
            listView.setMarked([])
        }
        let isNewDirectory = directory != self.directory
        if isNewDirectory {
            listView.folderSizes = [:]
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
            let controller = TransferController(title: String(localized: "Updating archive"),
                                                failureTitle: String(localized: "Cannot update archive"), window: window)
            let done = await controller.run(source: url.path, target: url.path) { progress, _ in
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
        if let filterMask {
            items = items.filter { $0.isFolder || FileMask.matches($0.name, filterMask) }
        }
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
        alert.addButton(withTitle: String(localized: "Cancel"))
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

    /// Show → All Files: removes the filter.
    @objc(cm_SrcAllFiles:)
    func srcAllFiles(_ sender: Any?) {
        filterMask = nil
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
        guard archive == nil, !urls.isEmpty else {
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
        let urls = clipboardFiles
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let moving = forceMove || Self.cutClipboard?.changeCount == pasteboard.changeCount
        if moving { Self.cutClipboard = nil }

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

    /// Copies or moves files into `destination` (paste, drag and drop). Items
    /// already in that folder are duplicated as "name copy" instead.
    private func transfer(_ urls: [URL], to destination: URL, moving: Bool) {
        guard let window = view.window else { return }
        Task {
            let controller = moving
                ? TransferController(title: String(localized: "Moving"), failureTitle: String(localized: "Moving failed"),
                                     window: window)
                : TransferController(title: String(localized: "Copying"), failureTitle: String(localized: "Copying failed"),
                                     window: window)
            _ = await controller.run(source: urls[0].deletingLastPathComponent().path, target: destination.path) {
                progress, resolveConflict in
                let total = urls.reduce(Int64(0)) { $0 + TransferEngine.totalSize(of: $1) }
                progress.update { $0.totalBytes = total }
                for url in urls {
                    var newName: String?
                    if url.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path {
                        if moving { continue }
                        newName = Self.copyName(for: url.lastPathComponent, in: destination)
                    }
                    let job = TransferJob(kind: moving ? .move : .copy, sources: [url], destination: destination,
                                          newName: newName)
                    _ = try await TransferEngine(job: job, progress: progress, reportsTotal: false,
                                                 resolveConflict: resolveConflict).run()
                }
                return urls
            }
            load(directory, selecting: urls.first?.lastPathComponent)
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
            add(Command.delete.title, Command.delete.selector)
            if archive == nil {
                menu.addItem(.separator())
                add(Command.packFiles.title, Command.packFiles.selector)
                if items.contains(where: { !$0.isDirectory && ArchiveReader.isArchive($0.name) }) {
                    add(Command.unpackFiles.title, Command.unpackFiles.selector)
                }
            }
        }
        return menu
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

    /// Alt+Shift+Enter: calculates the sizes of all folders in the panel.
    @objc(cm_CountDirContent:)
    func countDirContent(_ sender: Any?) {
        calculateSizes(of: listView.items.filter { $0.isFolder && !$0.isParent })
    }

    /// Calculates folder sizes in the background and shows them as they arrive.
    private func calculateSizes(of folders: [FileItem]) {
        guard archive == nil else { return }
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
            let job = TransferJob(kind: .copy, sources: [item.url], destination: directory, newName: name)
            Task {
                _ = await TransferController.run(job, in: window)
                self.load(self.directory, selecting: name)
            }
        }
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
        openInEditor(item.url)
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
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return archive == nil && !selectedItems.isEmpty
        case #selector(paste(_:)), #selector(moveItemsHere(_:)):
            return !clipboardFiles.isEmpty
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
            menuItem.state = sortOrder.column == sortColumn ? .on : .off
        } else if command == .reverseOrder {
            menuItem.state = sortOrder.ascending ? .off : .on
        } else if command == .goToParent {
            return directory.path != "/"
        } else if command == .branchView {
            menuItem.state = isBranchView ? .on : .off
        } else if command == .srcAllFiles || command == .srcUserSpec {
            menuItem.state = (filterMask == nil) == (command == .srcAllFiles) ? .on : .off
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

    func fileList(_ list: FileListView, contextMenuFor items: [FileItem]) -> NSMenu? {
        contextMenu(for: items)
    }

    func fileListCanDragItems(_ list: FileListView) -> Bool {
        archive == nil
    }

    func fileList(_ list: FileListView, drop urls: [URL], into folder: FileItem?, moving: Bool) -> Bool {
        if let archive, !(folder?.isParent == true && archive.folder.isEmpty) {
            guard !refuseReadOnlyArchive() else { return false }
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
            return true
        }
        let destination = archive != nil ? directory : (folder?.url ?? directory)
        transfer(urls, to: destination, moving: moving)
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
