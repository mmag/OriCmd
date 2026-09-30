import Foundation

/// Tables for the Lister's table view (Excel 2003 XML, HTML tables, CSV/TSV), as
/// the helper service reads them. The data is checked as coming from a stranger —
/// a service taken over could send anything: every count, index, span and text is
/// bounded, and anything amiss drops the whole reply.
nonisolated struct ViewerTable: Sendable {
    struct Sheet: Sendable {
        /// Empty for HTML tables and CSV (the view numbers them).
        var name: String
        var rowCount: Int
        var columnCount: Int
        /// The texts by row, then by column (merged cells keep theirs in the first);
        /// rows without any are left out, so a sheet claiming a million rows costs nothing.
        var rows: [Int: [Int: String]]

        func text(row: Int, column: Int) -> String? {
            rows[row]?[column]
        }
    }

    var sheets: [Sheet]

    private static let maxSheets = 256
    private static let maxRows = 1_048_576
    private static let maxColumns = 16_384
    private static let maxCells = 2_000_000
    private static let maxCellBytes = 4 * 32_767
    private static let maxBytes = 160 * 1024 * 1024

    init?(_ data: Data) {
        guard data.count <= Self.maxBytes, data.starts(with: Array("OTB1".utf8)) else { return nil }
        var reader = Reader(data: data, offset: 4)
        guard let sheetCount = reader.count(max: Self.maxSheets), sheetCount > 0 else { return nil }
        var sheets: [Sheet] = []
        var cellsLeft = Self.maxCells
        for _ in 0..<sheetCount {
            guard let name = reader.text(maxBytes: 1024),
                  let rowCount = reader.count(max: Self.maxRows),
                  let columnCount = reader.count(max: Self.maxColumns),
                  let cellCount = reader.count(max: cellsLeft) else { return nil }
            cellsLeft -= cellCount
            var rows: [Int: [Int: String]] = [:]
            for _ in 0..<cellCount {
                guard let row = reader.count(max: rowCount - 1), let column = reader.count(max: columnCount - 1),
                      let rowSpan = reader.count(max: rowCount - row), rowSpan > 0,
                      let columnSpan = reader.count(max: columnCount - column), columnSpan > 0,
                      let text = reader.text(maxBytes: Self.maxCellBytes) else { return nil }
                rows[row, default: [:]][column] = text
            }
            sheets.append(Sheet(name: name, rowCount: rowCount, columnCount: columnCount, rows: rows))
        }
        guard reader.offset == data.count else { return nil }
        self.sheets = sheets
    }

    /// Reads the little-endian counts and UTF-8 texts, within the data.
    private struct Reader {
        let data: Data
        var offset: Int

        /// A count from 0 to `max`; nil past it or past the data.
        mutating func count(max: Int) -> Int? {
            guard max >= 0, offset + 4 <= data.count else { return nil }
            let value = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            offset += 4
            return value <= max ? value : nil
        }

        /// A text of valid UTF-8 no longer than `maxBytes`.
        mutating func text(maxBytes: Int) -> String? {
            guard let length = count(max: maxBytes), offset + length <= data.count else { return nil }
            let bytes = data[data.startIndex + offset ..< data.startIndex + offset + length]
            offset += length
            return String(data: bytes, encoding: .utf8)
        }
    }

    /// The column's name as in spreadsheets: A…Z, AA…
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            index = (index - 1) / 26
        }
        return name
    }
}
