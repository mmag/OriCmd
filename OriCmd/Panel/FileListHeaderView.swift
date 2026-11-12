import AppKit

/// Column titles above the file list. Clicking a title sorts by that column,
/// clicking it again reverses the order; right click chooses optional columns.
/// A divider dragged sizes the column after it, Name taking the rest (a double click
/// gives the column its measured width again); the widths stay with the column set.
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
        didSet { if columns != oldValue { layoutDidChange() } }
    }
    /// The set's own column widths (the others are measured).
    var widths: [SortColumn: CGFloat] = [:] {
        didSet { if widths != oldValue { layoutDidChange() } }
    }
    var columnSet = ""
    /// A column set chosen in the menu ("" the Default view).
    var onChooseColumnSet: ((String) -> Void)?

    var sortOrder = SortOrder() {
        didSet { needsDisplay = true }
    }

    var onColumnClicked: ((SortColumn) -> Void)?
    /// While a divider is dragged: the columns shown when it started (none come or go
    /// meanwhile) and the widths, for the list to follow.
    var onResizeColumns: (([SortColumn], [SortColumn: CGFloat]) -> Void)?
    /// Widths to keep for the set: a divider let go or double-clicked, or the menu's reset.
    var onSetColumnWidths: (([SortColumn: CGFloat]) -> Void)?

    /// A divider being dragged: the column after it, where and how wide it started,
    /// how wide it may become, the columns shown and the set's widths then.
    private struct Resizing {
        let column: SortColumn
        let startX: CGFloat
        let startWidth: CGFloat
        let maximumWidth: CGFloat
        let shown: [SortColumn]
        let widths: [SortColumn: CGFloat]
    }
    private var resizing: Resizing?

    /// How far from a divider a press still takes it.
    private static let dividerTolerance: CGFloat = 4

    private static var resizeCursor: NSCursor {
        if #available(macOS 15, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    /// The columns as laid out in the header (1 point in from each side).
    private var layout: ColumnLayout {
        ColumnLayout(width: bounds.width - 2, columns: resizing?.shown ?? columns, widths: widths)
    }

    private func layoutDidChange() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    nonisolated override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()

        let layout = layout
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.chromeFont,
            .foregroundColor: Theme.chromeText,
        ]
        for column in layout.columns {
            let cell = layout.rect(for: column, y: 0, height: bounds.height).offsetBy(dx: 1, dy: 0)
            var title = Self.titles[column]!
            if column == sortOrder.column, !sortOrder.isUnsorted {
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

    /// The divider before a column is drawn on the last point of the column before it.
    private func dividerX(_ column: SortColumn, in layout: ColumnLayout) -> CGFloat {
        layout.rect(for: column, y: 0, height: 0).minX + 0.5
    }

    /// The column after the divider at `x`.
    private func divider(at x: CGFloat, in layout: ColumnLayout) -> SortColumn? {
        layout.column(leftEdgeNear: x - 0.5, tolerance: Self.dividerTolerance)
    }

    /// The middle of the divider before `column`, if it is shown (for the tests).
    func dividerX(before column: SortColumn) -> CGFloat? {
        let layout = layout
        return layout.columns.dropFirst().contains(column) ? dividerX(column, in: layout) : nil
    }

    override func resetCursorRects() {
        let layout = layout
        for column in layout.columns.dropFirst() {
            addCursorRect(NSRect(x: dividerX(column, in: layout) - Self.dividerTolerance, y: 0,
                                 width: Self.dividerTolerance * 2, height: bounds.height),
                          cursor: Self.resizeCursor)
        }
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
        let reset = NSMenuItem(title: String(localized: "Reset Column Widths"), action: #selector(resetWidths(_:)),
                               keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !widths.isEmpty
        menu.addItem(reset)
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
        menu.autoenablesItems = false
        return menu
    }

    @objc private func resetWidths(_ sender: NSMenuItem) {
        onSetColumnWidths?([:])
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
        let layout = layout
        guard let column = divider(at: point.x, in: layout) else {
            if let column = layout.column(at: point.x - 1) {
                onColumnClicked?(column)
            }
            return
        }
        if event.clickCount == 2 {
            var measured = widths
            measured[column] = nil
            if measured != widths { onSetColumnWidths?(measured) }
            return
        }
        // Name is not made narrower than columns start to be left out at (or than it
        // is, when already narrower), so none is left out while dragging.
        let width = layout.width(of: column)
        let others = layout.columns.dropFirst().filter { $0 != column }.reduce(0) { $0 + layout.width(of: $1) }
        let name = min(ColumnLayout.preferredNameWidth, layout.width(of: .name))
        resizing = Resizing(column: column, startX: point.x, startWidth: width,
                            maximumWidth: max(bounds.width - 2 - others - name, width),
                            shown: Array(layout.columns.dropFirst()), widths: widths)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resizing else { return }
        let x = convert(event.locationInWindow, from: nil).x
        // The divider follows the pointer: the column after it gives or takes the width.
        let proposed = (resizing.startWidth - (x - resizing.startX)).rounded()
        let width = min(max(proposed, min(ColumnLayout.minimumColumnWidth, resizing.startWidth)), resizing.maximumWidth)
        Self.resizeCursor.set()
        var changed = resizing.widths
        // Back where it started: the width it had (a measured one stays measured).
        if width != resizing.startWidth { changed[resizing.column] = width }
        guard changed != widths else { return }
        widths = changed
        onResizeColumns?(resizing.shown, widths)
    }

    override func mouseUp(with event: NSEvent) {
        guard let resizing else { return }
        self.resizing = nil
        layoutDidChange()
        if widths != resizing.widths { onSetColumnWidths?(widths) }
    }
}
