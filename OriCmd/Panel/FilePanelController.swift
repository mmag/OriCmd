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
    private var lastMask = "*.*"
    private var watcher: DirectoryWatcher?

    private struct HistoryEntry {
        let directory: URL
        let selectedName: String?
    }

    private static let historyLimit = 50
    private var backHistory: [HistoryEntry] = []
    private var forwardHistory: [HistoryEntry] = []

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

    var isActive: Bool {
        get { panelView.isActive }
        set { panelView.isActive = newValue }
    }

    init(directory: URL) {
        self.directory = directory
        super.init(nibName: nil, bundle: nil)

        listView.delegate = self
        panelView.headerView.sortOrder = sortOrder
        panelView.headerView.onColumnClicked = { [weak self] column in self?.sort(by: column) }
        panelView.pathBar.onClick = { [weak self] in self?.focus() }
        panelView.onGoToRoot = { [weak self] in self?.goToRoot() }
        panelView.onGoToParent = { [weak self] in self?.goToParent() }
        panelView.onVolumeSelected = { [weak self] volume in self?.load(volume.url) }

        load(directory)
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
        delegate?.filePanelDidChangeDirectory(self)
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
        guard directory.path != "/" else { return }
        load(directory.deletingLastPathComponent(), selecting: directory.lastPathComponent)
    }

    func goToRoot() {
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
        if directory.path != "/" {
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
        panelView.statusLabel.stringValue =
            "\(kilobytes(markedFiles)) k / \(kilobytes(files)) k in \(markedFiles.count) / \(files.count) file(s), "
            + "\(markedFolderCount) / \(folders.count) dir(s)"
    }

    private func askForMask(marking: Bool) {
        guard let window = view.window else { return }
        Prompt.text(marking ? "Select files" : "Unselect files", message: "File mask, e.g. *.txt;*.md",
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
        if item.isParent {
            goToParent()
        } else if item.isFolder || (enteringPackages && item.isDirectory) {
            load(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func present(_ error: Error, reading directory: URL) {
        Prompt.error("Cannot read folder \u{201C}\(directory.path)\u{201D}", error, in: view.window)
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

    /// F3: opens the file under the cursor in the Lister window.
    @objc(cm_List:)
    func list(_ sender: Any?) {
        guard let item = listView.currentItem, !item.isParent, !item.isFolder else {
            NSSound.beep()
            return
        }
        ListerWindowController.show(item.url)
    }

    /// F4: opens the file under the cursor in the default text editor.
    @objc(cm_Edit:)
    func edit(_ sender: Any?) {
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
        guard let window = view.window else { return }
        let initial = listView.currentItem.flatMap { $0.isParent ? nil : $0.name } ?? ""
        Prompt.text("New folder", message: "Folder name (use / for nested folders):",
                    initial: initial, okTitle: "Create", in: window) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            do {
                _ = try FileOperations.createDirectory(named: name, in: directory)
                let topLevel = name.split(separator: "/").first.map(String.init) ?? name
                load(directory, selecting: topLevel)
            } catch {
                Prompt.error("Cannot create folder \u{201C}\(name)\u{201D}", error, in: view.window)
            }
        }
    }

    /// F8 / Del / ⌘⌫: moves the selection to the Trash after confirmation.
    @objc(cm_Delete:)
    func delete(_ sender: Any?) {
        confirmDelete(permanently: false)
    }

    /// ⇧F8 / ⇧Del: deletes the selection permanently after confirmation.
    @objc(cm_DeletePermanently:)
    func deletePermanently(_ sender: Any?) {
        confirmDelete(permanently: true)
    }

    /// ⇧F6: renames the entry under the cursor in place.
    @objc(cm_RenameOnly:)
    func renameOnly(_ sender: Any?) {
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
            ? "\u{201C}\(items[0].name)\u{201D}"
            : "the selected \(items.count) files/folders"
        if permanently {
            Prompt.confirm("Do you really want to permanently delete \(what)?", message: "This cannot be undone.",
                           okTitle: "Delete", destructive: true, in: window) { [weak self] in
                self?.performDelete(items.map(\.url), permanently: true)
            }
        } else {
            Prompt.confirm("Do you really want to move \(what) to the Trash?",
                           okTitle: "Move to Trash", in: window) { [weak self] in
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
                Prompt.error("Cannot delete", error, in: view.window)
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
        }
        return true
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
        do {
            let url = try FileOperations.rename(item.url, to: newName)
            load(directory, selecting: url.lastPathComponent)
        } catch {
            Prompt.error("Cannot rename \u{201C}\(item.name)\u{201D}", error, in: view.window)
        }
    }

    func fileListMarksDidChange(_ list: FileListView) {
        updateStatus()
    }

    func fileListCursorDidMove(_ list: FileListView) {
        delegate?.filePanelCursorDidMove(self)
    }

    func fileList(_ list: FileListView, interceptKey event: NSEvent) -> Bool {
        delegate?.filePanel(self, interceptKey: event) ?? false
    }

    func fileList(_ list: FileListView, markGroup mark: Bool) {
        askForMask(marking: mark)
    }
}
