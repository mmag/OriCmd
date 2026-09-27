import AppKit

/// Horizontal geometry of the Full view columns: Name | Ext | Size | Date |
/// optional metadata columns | Attr. Fixed columns keep their width; Name takes the rest.
struct ColumnLayout {
    static let minimumNameWidth: CGFloat = 60
    /// Below this Name width, Attr and then optional columns are left out.
    static let preferredNameWidth: CGFloat = 140

    /// The columns shown in Full view, in order.
    static var visibleColumns: [SortColumn] {
        [.name, .ext, .size, .date] + Settings.extraColumns + [.attr]
    }

    private static var cachedWidths: (font: NSFont, columns: [SortColumn], widths: [(SortColumn, CGFloat)])?

    /// Widths of all columns but Name, measured with the current panel font.
    static var fixedWidths: [(SortColumn, CGFloat)] {
        let font = Theme.panelNumberFont
        let columns = visibleColumns
        if let cachedWidths, cachedWidths.font == font, cachedWidths.columns == columns { return cachedWidths.widths }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let sampleDate = formatter.string(from: Date(timeIntervalSince1970: 1_798_761_540))
        func width(_ sample: String) -> CGFloat {
            ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 12
        }
        let widths: [(SortColumn, CGFloat)] = columns.dropFirst().map { column in
            switch column {
            case .ext: (column, max(width("WWWW"), 44))
            case .size: (column, width("999 999 999"))
            case .date, .created: (column, width(sampleDate))
            case .attr: (column, width("rwxrwxrwx"))
            case .kind: (column, max(width("Markdown document"), 110))
            case .dimensions: (column, width("99999 × 99999"))
            case .duration: (column, width("99:59:59"))
            case .tags: (column, 110)
            case .name: (column, 0)
            }
        }
        cachedWidths = (font, columns, widths)
        return widths
    }

    private(set) var frames: [SortColumn: (x: CGFloat, width: CGFloat)] = [:]
    /// The columns that fit, in order (Name first).
    private(set) var columns: [SortColumn] = []
    /// The optional metadata columns in this layout.
    private(set) var extraColumns: [SortColumn] = []

    init(width: CGFloat) {
        var fixedWidths = Self.fixedWidths
        // Keep names readable: drop Attr first, then optional columns from the right.
        while width - fixedWidths.reduce(0, { $0 + $1.1 }) < Self.preferredNameWidth,
              let index = fixedWidths.firstIndex(where: { $0.0 == .attr })
                ?? fixedWidths.lastIndex(where: { SortColumn.extras.contains($0.0) }) {
            fixedWidths.remove(at: index)
        }
        let fixed = fixedWidths.reduce(0) { $0 + $1.1 }
        let nameWidth = max(width - fixed, Self.minimumNameWidth)
        frames[.name] = (0, nameWidth)
        var x = nameWidth
        for (column, columnWidth) in fixedWidths {
            frames[column] = (x, columnWidth)
            x += columnWidth
        }
        columns = [.name] + fixedWidths.map(\.0)
        extraColumns = columns.filter(SortColumn.extras.contains)
    }

    func contains(_ column: SortColumn) -> Bool {
        frames[column] != nil
    }

    func rect(for column: SortColumn, y: CGFloat, height: CGFloat) -> NSRect {
        let frame = frames[column]!
        return NSRect(x: frame.x, y: y, width: frame.width, height: height)
    }

    func column(at x: CGFloat) -> SortColumn? {
        frames.first { x >= $0.value.x && x < $0.value.x + $0.value.width }?.key
    }
}
