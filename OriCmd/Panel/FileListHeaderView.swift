import AppKit

/// Column titles above the file list. Clicking a title sorts by that column,
/// clicking it again reverses the order; right click chooses optional columns.
final class FileListHeaderView: NSView {
    static let titles: [SortColumn: String] = [
        .name: String(localized: "Name"), .ext: String(localized: "Ext"), .size: String(localized: "Size"),
        .date: String(localized: "Date"), .attr: String(localized: "Attr"), .kind: String(localized: "Kind"),
        .created: String(localized: "Created"), .dimensions: String(localized: "Dimensions"),
        .duration: String(localized: "Duration"), .tags: String(localized: "Tags"),
    ]

    var sortOrder = SortOrder() {
        didSet { needsDisplay = true }
    }

    var onColumnClicked: ((SortColumn) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()

        let layout = ColumnLayout(width: bounds.width - 2)
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

    /// Right click: optional metadata columns (shared by both panels).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let shown = Settings.extraColumns
        for column in SortColumn.extras {
            let item = NSMenuItem(title: Self.titles[column] ?? "", action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = shown.contains(column) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = SortColumn(rawValue: raw) else { return }
        var columns = Settings.extraColumns
        if let index = columns.firstIndex(of: column) {
            columns.remove(at: index)
        } else {
            columns.append(column)
        }
        Settings.extraColumns = SortColumn.extras.filter(columns.contains)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let column = ColumnLayout(width: bounds.width - 2).column(at: point.x - 1) {
            onColumnClicked?(column)
        }
    }
}
