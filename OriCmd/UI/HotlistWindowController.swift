import AppKit

/// "Configure" for the directory hotlist: reorder and remove favourite folders.
final class HotlistWindowController: NSWindowController {
    static let shared = HotlistWindowController()

    private let table = NSTableView()
    private var paths: [String] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Directory Hotlist")
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        paths = Hotlist.directories
        table.reloadData()
        super.showWindow(sender)
    }

    private func buildContent() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = String(localized: "Folder")
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let buttons = NSStackView(views: [
            NSButton(title: String(localized: "Move Up"), target: self, action: #selector(moveEntryUp(_:))),
            NSButton(title: String(localized: "Move Down"), target: self, action: #selector(moveEntryDown(_:))),
            NSButton(title: String(localized: "Remove"), target: self, action: #selector(remove(_:))),
        ])
        let stack = NSStackView(views: [scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    private func move(by offset: Int) {
        let row = table.selectedRow
        guard paths.indices.contains(row), paths.indices.contains(row + offset) else { return }
        paths.swapAt(row, row + offset)
        save(selecting: row + offset)
    }

    @objc private func moveEntryUp(_ sender: Any?) {
        move(by: -1)
    }

    @objc private func moveEntryDown(_ sender: Any?) {
        move(by: 1)
    }

    @objc private func remove(_ sender: Any?) {
        let row = table.selectedRow
        guard paths.indices.contains(row) else { return }
        paths.remove(at: row)
        save(selecting: min(row, paths.count - 1))
    }

    private func save(selecting row: Int) {
        Hotlist.set(paths)
        table.reloadData()
        if row >= 0 {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
}

extension HotlistWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        paths.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        (paths[row] as NSString).abbreviatingWithTildeInPath
    }
}
