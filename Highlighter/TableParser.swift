import Foundation

/// Reads tables for the Lister's table view: Excel 2003 XML (SpreadsheetML), the
/// tables of an HTML page (what many programs export as ".xls"), and CSV/TSV. It
/// runs in this locked-down process, as the files are strangers' data; the
/// result is plain data (see `TableData`) that OriCmd checks before showing it.
enum TableParser {
    /// Sizes past which reading stops (what was read is shown).
    static let maxSheets = 256
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCells = 2_000_000
    static let maxCellLength = 32_767
    static let maxTextBytes = 64 * 1024 * 1024

    static func parse(_ text: String, format: String) -> Data? {
        let builder = TableBuilder()
        switch format {
        case "spreadsheetml": SpreadsheetMLReader(builder).read(text)
        case "html": HTMLTableReader(builder).read(text)
        case "csv": CSVReader(builder, delimiter: nil).read(text)
        case "tsv": CSVReader(builder, delimiter: "\t").read(text)
        default: return nil
        }
        return builder.sheets.isEmpty ? nil : builder.encoded()
    }
}

/// Collects sheets and cells within the limits and writes them out as
/// "OTB1", sheet count, then per sheet: name, row count, column count, cell count
/// and cells (row, column, rows spanned, columns spanned, text), all counts UInt32
/// little-endian, texts as their UTF-8 length and bytes.
final class TableBuilder {
    struct Cell {
        var row: Int, column: Int, rowSpan: Int, columnSpan: Int, text: String
    }

    struct Sheet {
        var name: String
        var rowCount = 0, columnCount = 0
        var cells: [Cell] = []
    }

    private(set) var sheets: [Sheet] = []
    private var cellCount = 0
    private var textBytes = 0
    /// A limit was reached: nothing more is added.
    private(set) var isFull = false

    func beginSheet(_ name: String) {
        guard !isFull else { return }
        guard sheets.count < TableParser.maxSheets else {
            isFull = true
            return
        }
        sheets.append(Sheet(name: String(name.prefix(256))))
    }

    /// Adds a cell (0-based row and column); empty ones only widen the sheet.
    func add(row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, text: String) {
        guard !isFull, !sheets.isEmpty else { return }
        guard row >= 0, column >= 0, row < TableParser.maxRows, column < TableParser.maxColumns else { return }
        let rowSpan = min(max(rowSpan, 1), TableParser.maxRows - row)
        let columnSpan = min(max(columnSpan, 1), TableParser.maxColumns - column)
        let last = sheets.count - 1
        sheets[last].rowCount = max(sheets[last].rowCount, row + rowSpan)
        sheets[last].columnCount = max(sheets[last].columnCount, column + columnSpan)
        let text = text.count > TableParser.maxCellLength ? String(text.prefix(TableParser.maxCellLength)) : text
        guard !text.isEmpty || rowSpan > 1 || columnSpan > 1 else { return }
        guard cellCount < TableParser.maxCells, textBytes + text.utf8.count <= TableParser.maxTextBytes else {
            isFull = true
            return
        }
        cellCount += 1
        textBytes += text.utf8.count
        sheets[last].cells.append(Cell(row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan, text: text))
    }

    func encoded() -> Data {
        var data = Data("OTB1".utf8)
        func put(_ value: Int) {
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) }
        }
        func put(_ text: String) {
            put(text.utf8.count)
            data.append(contentsOf: text.utf8)
        }
        put(sheets.count)
        for sheet in sheets {
            put(sheet.name)
            put(sheet.rowCount)
            put(sheet.columnCount)
            put(sheet.cells.count)
            for cell in sheet.cells {
                put(cell.row)
                put(cell.column)
                put(cell.rowSpan)
                put(cell.columnSpan)
                put(cell.text)
            }
        }
        return data
    }
}

// MARK: - Excel 2003 XML

/// Worksheets, rows and cells of SpreadsheetML: `ss:Index` skips rows and columns,
/// `ss:MergeAcross`/`ss:MergeDown` merge, a cell's value is its Data (not a comment's).
final class SpreadsheetMLReader: NSObject, XMLParserDelegate {
    private let builder: TableBuilder
    private var row = -1
    private var nextColumn = 0
    private var cell: (column: Int, rowSpan: Int, columnSpan: Int)?
    private var dataDepth = 0
    private var commentDepth = 0
    private var value = ""
    private var valueType: String?
    private var hasSheet = false

    init(_ builder: TableBuilder) {
        self.builder = builder
    }

    func read(_ text: String) {
        // The text is decoded already: its declaration must not name another encoding.
        let parser = XMLParser(data: Data(Self.declaringUTF8(text).utf8))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
    }

    private static func declaringUTF8(_ text: String) -> String {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return text }
        let declaration = text[..<end.lowerBound]
        guard let encoding = declaration.range(of: #"encoding\s*=\s*["'][^"']*["']"#, options: .regularExpression)
        else { return text }
        return text.replacingCharacters(in: encoding, with: #"encoding="UTF-8""#)
    }

    /// 2024-01-31T00:00:00.000 as 2024-01-31, 2024-01-31T12:30:00.000 as 2024-01-31 12:30.
    private static func readableDate(_ value: String) -> String {
        let parts = value.split(separator: "T", maxSplits: 1)
        guard parts.count == 2 else { return value }
        let time = parts[1].split(separator: ".").first.map(String.init) ?? ""
        if time == "00:00:00" { return String(parts[0]) }
        return parts[0] + " " + (time.hasSuffix(":00") ? String(time.dropLast(3)) : time)
    }

    private func attribute(_ attributes: [String: String], _ name: String) -> String? {
        attributes["ss:" + name] ?? attributes[name]
    }

    private func number(_ attributes: [String: String], _ name: String) -> Int? {
        attribute(attributes, name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if builder.isFull { parser.abortParsing() }
        switch name {
        case "Worksheet":
            builder.beginSheet(attribute(attributes, "Name") ?? "")
            hasSheet = true
            row = -1
        case "Row" where hasSheet:
            row = (number(attributes, "Index").map { $0 - 1 }) ?? row + 1
            nextColumn = 0
        case "Cell" where hasSheet && row >= 0:
            let column = (number(attributes, "Index").map { $0 - 1 }) ?? nextColumn
            let across = max(number(attributes, "MergeAcross") ?? 0, 0)
            let down = max(number(attributes, "MergeDown") ?? 0, 0)
            cell = (column, down + 1, across + 1)
            nextColumn = column + across + 1
            value = ""
        case "Comment":
            commentDepth += 1
        case "Data" where cell != nil && commentDepth == 0:
            if dataDepth == 0 { valueType = attribute(attributes, "Type") }
            dataDepth += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "Cell":
            if let cell {
                builder.add(row: row, column: cell.column, rowSpan: cell.rowSpan, columnSpan: cell.columnSpan,
                            text: valueType == "DateTime" ? Self.readableDate(value) : value)
            }
            cell = nil
            valueType = nil
        case "Comment":
            commentDepth = max(commentDepth - 1, 0)
        case "Data" where dataDepth > 0 && commentDepth == 0:
            dataDepth -= 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if dataDepth > 0, commentDepth == 0, value.utf8.count <= 4 * TableParser.maxCellLength {
            value += string
        }
    }
}

// MARK: - HTML tables

/// The tables of an HTML page, each a sheet: `<tr>` rows of `<td>`/`<th>` cells
/// with colspan and rowspan, the text of a cell with its tags dropped and entities
/// decoded. Tables inside cells count as the cell's text. Tolerant of what browsers
/// forgive (unclosed cells and rows, uppercase tags).
final class HTMLTableReader {
    private let builder: TableBuilder
    private var depth = 0
    private var row = -1
    private var column = 0
    /// Columns still taken by cells of rows above (rowspan): column → last row.
    private var taken: [Int: Int] = [:]
    private var cell: (column: Int, rowSpan: Int, columnSpan: Int)?
    private var value = ""
    private var valueLength = 0

    init(_ builder: TableBuilder) {
        self.builder = builder
    }

    func read(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var textStart = 0
        func flushText(upTo end: Int) {
            if cell != nil, end > textStart, valueLength <= TableParser.maxCellLength {
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[textStart..<min(end, textStart + TableParser.maxCellLength)])
                value += String(piece)
                valueLength += piece.count
            }
        }
        while index < scalars.count, !builder.isFull {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }
            flushText(upTo: index)
            // A comment, a declaration, or a tag.
            if Self.matches(scalars, at: index, "<!--") {
                index = Self.find(scalars, "-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                textStart = index
                continue
            }
            guard let end = Self.tagEnd(scalars, from: index + 1) else {
                index = scalars.count
                break
            }
            let tag = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            index = end + 1
            textStart = index
            let (name, closing, attributes) = Self.parseTag(tag)
            // Scripts and styles hold no table text.
            if !closing, name == "script" || name == "style" {
                index = Self.find(scalars, "</" + name, from: index, caseInsensitive: true) ?? scalars.count
                textStart = index
                continue
            }
            handle(name: name, closing: closing, attributes: attributes)
        }
        flushText(upTo: scalars.count)
        endCell()
    }

    private func handle(name: String, closing: Bool, attributes: [String: String]) {
        switch (name, closing) {
        case ("table", false):
            if depth == 0 {
                builder.beginSheet("")
                row = -1
                taken = [:]
            } else if cell != nil {
                value += " "
            }
            depth += 1
        case ("table", true):
            if depth == 1 { endCell() }
            depth = max(depth - 1, 0)
        case ("tr", false) where depth == 1:
            endCell()
            row += 1
            column = 0
        case ("td", false) where depth == 1, ("th", false) where depth == 1:
            endCell()
            if row < 0 {
                row = 0
                column = 0
            }
            while let last = taken[column], last >= row { column += 1 }
            let rowSpan = min(max(Int(attributes["rowspan"] ?? "") ?? 1, 1), 65_534)
            let columnSpan = min(max(Int(attributes["colspan"] ?? "") ?? 1, 1), 1_000)
            cell = (column, rowSpan, columnSpan)
            if rowSpan > 1 {
                for taken in column..<(column + columnSpan) { self.taken[taken] = row + rowSpan - 1 }
            }
            column += columnSpan
            value = ""
            valueLength = 0
        case ("td", true) where depth == 1, ("th", true) where depth == 1, ("tr", true) where depth == 1:
            endCell()
        case ("br", _), ("p", _), ("div", _), ("li", _), ("td", _), ("th", _), ("tr", _):
            if cell != nil { value += " " }
        default:
            break
        }
    }

    private func endCell() {
        guard let cell else { return }
        let text = Self.decodeEntities(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        builder.add(row: row, column: cell.column, rowSpan: cell.rowSpan, columnSpan: cell.columnSpan, text: text)
        self.cell = nil
        value = ""
        valueLength = 0
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ text: String) -> Bool {
        let pattern = Array(text.unicodeScalars)
        guard index + pattern.count <= scalars.count else { return false }
        return scalars[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private static func find(_ scalars: [Unicode.Scalar], _ text: String, from start: Int,
                             caseInsensitive: Bool = false) -> Int? {
        let pattern = Array((caseInsensitive ? text.lowercased() : text).unicodeScalars)
        guard !pattern.isEmpty, start <= scalars.count - pattern.count else { return nil }
        for index in start...(scalars.count - pattern.count) {
            var matched = true
            for (offset, expected) in pattern.enumerated() {
                var scalar = scalars[index + offset]
                if caseInsensitive, ("A"..."Z").contains(scalar) {
                    scalar = Unicode.Scalar(scalar.value + 32) ?? scalar
                }
                if scalar != expected {
                    matched = false
                    break
                }
            }
            if matched { return index }
        }
        return nil
    }

    /// The `>` closing a tag, quotes respected.
    private static func tagEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var quote: Unicode.Scalar?
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The name (lowercased), whether it closes, and the attributes (names lowercased).
    private static func parseTag(_ tag: String) -> (String, Bool, [String: String]) {
        var body = Substring(tag)
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
        var attributes: [String: String] = [:]
        if !closing, ["td", "th"].contains(name) {
            let pattern = #"([A-Za-z-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+)"#
            let text = String(body.dropFirst(name.count))
            let expression = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            expression?.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let key = Range(match.range(at: 1), in: text),
                      let value = Range(match.range(at: 2), in: text) else { return }
                attributes[text[key].lowercased()] = text[value].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return (name, closing, attributes)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "laquo": "«", "raquo": "»",
        "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "euro": "€", "times": "×", "deg": "°",
        "minus": "−", "shy": "", "bull": "•", "le": "≤", "ge": "≥", "ne": "≠", "plusmn": "±", "sect": "§", "no": "№",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let name = after[..<semicolon]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    replacement = named[String(name).lowercased()]
                }
                if let replacement {
                    result += replacement
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}

// MARK: - CSV

/// CSV (RFC 4180: quotes, doubled quotes, line breaks inside quotes) with the
/// delimiter the first lines agree on (`,` `;` tab `|`), or TSV.
final class CSVReader {
    private let builder: TableBuilder
    private let delimiter: Character?

    init(_ builder: TableBuilder, delimiter: Character?) {
        self.builder = builder
        self.delimiter = delimiter
    }

    func read(_ text: String) {
        let delimiter = delimiter ?? Self.guessDelimiter(text)
        builder.beginSheet("")
        var row = 0, column = 0
        var field = ""
        var fieldLength = 0
        var quoted = false, wasQuoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let character = pending {
                pending = nil
                return character
            }
            return iterator.next()
        }
        func append(_ character: Character) {
            guard fieldLength < TableParser.maxCellLength else { return }
            field.append(character)
            fieldLength += 1
        }
        func endField() {
            builder.add(row: row, column: column, text: field)
            field = ""
            fieldLength = 0
            wasQuoted = false
            column += 1
        }
        while let character = next(), !builder.isFull {
            if quoted {
                if character == "\"" {
                    let following = next()
                    if following == "\"" {
                        append("\"")
                    } else {
                        // The closing quote; what follows is read as usual.
                        quoted = false
                        wasQuoted = true
                        pending = following
                    }
                } else {
                    append(character)
                }
                continue
            }
            switch character {
            case "\"" where fieldLength == 0 && !wasQuoted:
                quoted = true
            case delimiter:
                endField()
            case "\n", "\r\n", "\r":
                endField()
                row += 1
                column = 0
            default:
                append(character)
            }
        }
        if !field.isEmpty || column > 0 || wasQuoted { endField() }
    }

    static func guessDelimiter(_ text: String) -> Character {
        let lines = text.prefix(16_384).split(whereSeparator: \.isNewline).prefix(20)
        var best: (delimiter: Character, score: Int) = (",", -1)
        for candidate: Character in [",", ";", "\t", "|"] {
            let counts = lines.map { line in line.filter { $0 == candidate }.count }
            guard let first = counts.first, first > 0 else { continue }
            let agreeing = counts.filter { $0 == first }.count
            let score = agreeing * 1000 + first
            if score > best.score { best = (candidate, score) }
        }
        return best.delimiter
    }
}
