import AppKit

/// Ctrl+F8: a folder tree shown in place of a panel's file list. As in classic
/// Total Commander, the other panel shows the contents of the selected folder.
final class DirectoryTreePanel: NSView {
    /// A folder in the tree; children are read on first use.
    final class Node {
        let url: URL
        private let showsHidden: Bool
        private var loadedChildren: [Node]?

        init(url: URL, showsHidden: Bool) {
            self.url = url
            self.showsHidden = showsHidden
        }

        var name: String { url.path == "/" ? "/" : url.lastPathComponent }

        var children: [Node] {
            if let loadedChildren { return loadedChildren }
            let folders = ((try? DirectoryListing.items(in: url)) ?? [])
                .filter { $0.isFolder && !$0.isSymlink && (showsHidden || !$0.isHidden) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Node(url: $0.url, showsHidden: showsHidden) }
            loadedChildren = folders
            return folders
        }
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("TreeCell")

    private let titleBar = PathBar()
    private let outline = TreeOutlineView()
    private let root: Node

    /// The selected folder changed.
    var onSelect: ((URL) -> Void)?
    /// Tab / Enter: move to the other panel.
    var onSwitchPanel: (() -> Void)?
    /// A view command (Brief/Full/Tree) closes the tree.
    var onClose: ((FileListView.ViewMode) -> Void)?

    var selectedURL: URL? {
        (outline.item(atRow: outline.selectedRow) as? Node)?.url
    }

    init(root: URL, showsHidden: Bool) {
        self.root = Node(url: root, showsHidden: showsHidden)
        super.init(frame: .zero)

        titleBar.path = String(localized: "Tree")
        titleBar.showsMask = false
        titleBar.isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Theme.rowHeight
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.onSwitchPanel = { [weak self] in self?.onSwitchPanel?() }

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder

        for view in [titleBar, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor, constant: 29),
            scrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
        outline.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func focus() {
        window?.makeFirstResponder(outline)
    }

    /// Expands the tree down to `url` and selects it.
    func reveal(_ url: URL) {
        var node = root
        var path = [root]
        for component in url.standardizedFileURL.pathComponents.dropFirst(root.url.pathComponents.count) {
            guard let child = node.children.first(where: { $0.url.lastPathComponent == component }) else { break }
            path.append(child)
            node = child
        }
        path.dropLast().forEach { outline.expandItem($0) }
        let row = outline.row(forItem: path.last)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    @objc(cm_SrcTree:)
    func srcTree(_ sender: Any?) {
        onClose?(.full)
    }

    @objc(cm_SrcLong:)
    func srcLong(_ sender: Any?) {
        onClose?(.full)
    }

    @objc(cm_SrcShort:)
    func srcShort(_ sender: Any?) {
        onClose?(.brief)
    }
}

extension DirectoryTreePanel: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root }
        return node.children[index]
    }

    /// Every folder shows a disclosure triangle; children are only read when a
    /// folder is expanded (reading ahead would touch protected folders such as
    /// Desktop and trigger privacy prompts).
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()
        cell.textField?.stringValue = (item as? Node)?.name ?? ""
        cell.imageView?.image = NSWorkspace.shared.icon(for: .folder)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let url = selectedURL {
            onSelect?(url)
        }
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.font = Theme.panelFont
        text.lineBreakMode = .byTruncatingTail
        for view in [image, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.imageView = image
        cell.textField = text
        return cell
    }
}

/// Tab and Enter move to the other panel instead of editing the tree.
private final class TreeOutlineView: NSOutlineView {
    var onSwitchPanel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .tab?, .backTab?, .carriageReturn?, .enter?:
            onSwitchPanel?()
        default:
            super.keyDown(with: event)
        }
    }
}
