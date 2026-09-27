import AppKit

/// Column titles above the file list. Clicking a title sorts by that column,
/// clicking it again reverses the order.
final class FileListHeaderView: NSView {
    private static let titles: [SortColumn: String] = [
        .name: "Name", .ext: "Ext", .size: "Size", .date: "Date", .attr: "Attr",
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
        for column in SortColumn.allCases {
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let column = ColumnLayout(width: bounds.width - 2).column(at: point.x - 1) {
            onColumnClicked?(column)
        }
    }
}
