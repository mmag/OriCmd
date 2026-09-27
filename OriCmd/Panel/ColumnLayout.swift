import AppKit

/// Horizontal geometry of the Full view columns: Name | Ext | Size | Date | Attr.
/// Fixed columns keep their width; Name takes the rest.
struct ColumnLayout {
    static let fixedWidths: [(SortColumn, CGFloat)] = [(.ext, 50), (.size, 84), (.date, 118), (.attr, 74)]
    static let minimumNameWidth: CGFloat = 60

    private(set) var frames: [SortColumn: (x: CGFloat, width: CGFloat)] = [:]

    init(width: CGFloat) {
        let fixed = Self.fixedWidths.reduce(0) { $0 + $1.1 }
        let nameWidth = max(width - fixed, Self.minimumNameWidth)
        frames[.name] = (0, nameWidth)
        var x = nameWidth
        for (column, columnWidth) in Self.fixedWidths {
            frames[column] = (x, columnWidth)
            x += columnWidth
        }
    }

    func rect(for column: SortColumn, y: CGFloat, height: CGFloat) -> NSRect {
        let frame = frames[column]!
        return NSRect(x: frame.x, y: y, width: frame.width, height: height)
    }

    func column(at x: CGFloat) -> SortColumn? {
        SortColumn.allCases.first { column in
            let frame = frames[column]!
            return x >= frame.x && x < frame.x + frame.width
        }
    }
}
