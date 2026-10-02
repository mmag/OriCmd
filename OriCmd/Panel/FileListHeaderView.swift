import AppKit

/// Column titles above the file list. Clicking a title sorts by that column,
/// clicking it again reverses the order; right click chooses optional columns.
final class FileListHeaderView: NSView {
    static let titles: [SortColumn: String] = [
        .name: String(localized: "Name"), .ext: String(localized: "Ext"), .size: String(localized: "Size"),
        .date: String(localized: "Date"), .attr: String(localized: "Attr"), .kind: String(localized: "Kind"),
        .created: String(localized: "Created"), .dimensions: String(localized: "Dimensions"),
        .duration: String(localized: "Duration"), .tags: String(localized: "Tags"),
        .comment: String(localized: "Comment"),
    ]

    /// The columns after Name, and the column set they come from ("" the Default view).
    var columns = ColumnSet.standard {
        didSet { if columns != oldValue { needsDisplay = true } }
    }
    var columnSet = ""
    /// A column set chosen in the menu ("" the Default view).
    var onChooseColumnSet: ((String) -> Void)?

    var sortOrder = SortOrder() {
        didSet { needsDisplay = true }
    }

    var onColumnClicked: ((SortColumn) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()

        let layout = ColumnLayout(width: bounds.width - 2, columns: columns)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.chromeFont,
            .foregroundColor: Theme.chromeText,
        ]
        for column in layout.columns {
            let cell = layout.rect(for: column, y: 0, height: bounds.height).offsetBy(dx: 1, dy: 0)
            var title = Self.titles[column]!
            if column == sortOrder.column {
                title += sortOrder.ascending ? " ▴" : " ▾"
            }
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(
                at: NSPoint(x: cell.minX + 4, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
            Theme.separator.setFill()
            NSRect(x: cell.maxX - 1, y: 2, width: 1, height: bounds.height - 4).fill()
        }
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Right click: the columns of the set shown (changed for every panel using
    /// it), and the column sets to choose from.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for column in SortColumn.optional {
            let item = NSMenuItem(title: Self.titles[column] ?? "", action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = columns.contains(column) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for name in [""] + ColumnSet.saved.map(\.name) {
            let item = NSMenuItem(title: name.isEmpty ? String(localized: "Default Columns") : name,
                                  action: #selector(chooseSet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == columnSet ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: String(localized: "Column Sets…"),
                                action: #selector(MainViewController.configureColumnSets(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = SortColumn(rawValue: raw) else { return }
        var changed = columns
        if let index = changed.firstIndex(of: column) {
            changed.remove(at: index)
        } else {
            changed.append(column)
        }
        ColumnSet.setColumns(changed, of: columnSet)
    }

    @objc private func chooseSet(_ sender: NSMenuItem) {
        onChooseColumnSet?(sender.representedObject as? String ?? "")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let column = ColumnLayout(width: bounds.width - 2, columns: columns).column(at: point.x - 1) {
            onColumnClicked?(column)
        }
    }
}
