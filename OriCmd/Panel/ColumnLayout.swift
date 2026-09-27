import AppKit

/// Horizontal geometry of the Full view columns: Name | Ext | Size | Date | Attr.
/// Fixed columns keep their width; Name takes the rest.
struct ColumnLayout {
    static let minimumNameWidth: CGFloat = 60

    private static var cachedWidths: (font: NSFont, widths: [(SortColumn, CGFloat)])?

    /// Widths of Ext, Size, Date and Attr, measured with the current panel font.
    static var fixedWidths: [(SortColumn, CGFloat)] {
        let font = Theme.panelNumberFont
        if let cachedWidths, cachedWidths.font == font { return cachedWidths.widths }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let sampleDate = formatter.string(from: Date(timeIntervalSince1970: 1_798_761_540))
        func width(_ sample: String) -> CGFloat {
            ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 12
        }
        let widths: [(SortColumn, CGFloat)] = [
            (.ext, max(width("WWWW"), 44)),
            (.size, width("999 999 999")),
            (.date, width(sampleDate)),
            (.attr, width("rwxrwxrwx")),
        ]
        cachedWidths = (font, widths)
        return widths
    }

    private(set) var frames: [SortColumn: (x: CGFloat, width: CGFloat)] = [:]

    init(width: CGFloat) {
        let fixedWidths = Self.fixedWidths
        let fixed = fixedWidths.reduce(0) { $0 + $1.1 }
        let nameWidth = max(width - fixed, Self.minimumNameWidth)
        frames[.name] = (0, nameWidth)
        var x = nameWidth
        for (column, columnWidth) in fixedWidths {
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
