import AppKit

@MainActor
protocol FilePanelControllerDelegate: AnyObject {
    func filePanelDidBecomeActive(_ panel: FilePanelController)
    func filePanelSwitchPanel(_ panel: FilePanelController)
    func filePanelDidChangeDirectory(_ panel: FilePanelController)
}

/// Owns one panel: its current directory, listing, sort order and view.
final class FilePanelController: NSObject {
    let view = PanelView()
    weak var delegate: FilePanelControllerDelegate?

    private(set) var directory: URL
    private var entries: [FileItem] = []

    var sortOrder = SortOrder() {
        didSet {
            view.headerView.sortOrder = sortOrder
            refreshList(selecting: listView.currentItem?.name)
        }
    }

    var showsHidden = false {
        didSet { refreshList(selecting: listView.currentItem?.name) }
    }

    var listView: FileListView { view.listView }

    var isActive: Bool {
        get { view.isActive }
        set { view.isActive = newValue }
    }

    init(directory: URL) {
        self.directory = directory
        super.init()

        listView.delegate = self
        view.headerView.sortOrder = sortOrder
        view.headerView.onColumnClicked = { [weak self] column in self?.sort(by: column) }
        view.pathBar.onClick = { [weak self] in self?.focus() }
        view.onGoToRoot = { [weak self] in self?.goToRoot() }
        view.onGoToParent = { [weak self] in self?.goToParent() }
        view.onVolumeSelected = { [weak self] volume in self?.load(volume.url) }

        load(directory)
    }

    func focus() {
        view.window?.makeFirstResponder(listView)
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
        self.directory = directory
        self.entries = entries
        view.show(directory: directory, volumes: Volume.mounted())
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
        if let window = view.window {
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
}
