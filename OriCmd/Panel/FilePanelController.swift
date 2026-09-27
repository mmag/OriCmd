import AppKit

@MainActor
protocol FilePanelControllerDelegate: AnyObject {
    func filePanelDidBecomeActive(_ panel: FilePanelController)
    func filePanelSwitchPanel(_ panel: FilePanelController)
    func filePanelDidChangeDirectory(_ panel: FilePanelController)
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

    func focus() {
        panelView.window?.makeFirstResponder(listView)
    }

    // MARK: - Navigation

    /// Reads `directory` and shows it, placing the cursor on `name` if given.
    func load(_ directory: URL, selecting name: String? = nil) {
        let directory = directory.standardizedFileURL
        let entries: [FileItem]
        do {
            entries = try DirectoryListing.items(in: directory)
        } catch {
            present(error, reading: directory)
            return
        }
        if directory != self.directory {
            listView.setMarked([])
        }
        self.directory = directory
        self.entries = entries
        panelView.show(directory: directory, volumes: Volume.mounted())
        refreshList(selecting: name)
        delegate?.filePanelDidChangeDirectory(self)
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

    private func refreshList(selecting name: String?) {
        var items = showsHidden ? entries : entries.filter { !$0.isHidden }
        items = sortOrder.sorted(items)
        if directory.path != "/" {
            items.insert(.parent(of: directory), at: 0)
        }
        let cursor = name.flatMap { name in items.firstIndex { $0.name == name } } ?? 0
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
        let field = NSTextField(string: lastMask)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)

        let alert = NSAlert()
        alert.messageText = marking ? "Select files" : "Unselect files"
        alert.informativeText = "File mask, e.g. *.txt;*.md"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            lastMask = field.stringValue
            let names = listView.items
                .filter { !$0.isParent && !$0.isFolder && FileMask.matches($0.name, field.stringValue) }
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
        let alert = NSAlert()
        alert.messageText = "Cannot read folder \u{201C}\(directory.path)\u{201D}"
        alert.informativeText = error.localizedDescription
        if let window = panelView.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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

    func fileListMarksDidChange(_ list: FileListView) {
        updateStatus()
    }

    func fileList(_ list: FileListView, markGroup mark: Bool) {
        askForMask(marking: mark)
    }
}
