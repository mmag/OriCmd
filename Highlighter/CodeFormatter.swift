import Foundation

/// JSON and XML laid out for reading (the Lister's formatting; JavaScript, CSS and
/// HTML go to js-beautify). Both work on tokens and never fail on a broken file:
/// what they do not understand is kept as it is. Indentation stops deepening after
/// `maxDepth` levels and the result is bounded, so a file nested a million levels
/// deep cannot make it huge.
enum CodeFormatter {
    private static let indent = 2
    private static let maxDepth = 64

    /// At most this much larger than the text (indentation and line breaks).
    private static func outputLimit(_ inputCount: Int) -> Int {
        inputCount * 4 + 1_000_000
    }

    /// JSON (comments too, as JSONC and JSON5 have them), one value a line, strings,
    /// numbers and the order of keys as they are; empty objects and arrays stay `{}`
    /// and `[]`.
    static func json(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var output = Output(limit: outputLimit(bytes.count))
        var depth = 0, index = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        func nextSignificant(after position: Int) -> Int {
            var position = position
            while position < bytes.count, isSpace(bytes[position]) { position += 1 }
            return position
        }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
                continue
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                // A string, escapes and all (JSON5 allows single quotes).
                var end = index + 1
                while end < bytes.count, bytes[end] != byte {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                end = min(end + 1, bytes.count)
                output.append(bytes[index..<end])
                index = end
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                output.append(byte)
                let close = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                let next = nextSignificant(after: index + 1)
                if next < bytes.count, bytes[next] == close {
                    output.append(close)
                    index = next + 1
                } else {
                    depth += 1
                    output.newLine(depth: depth)
                    index += 1
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth = max(depth - 1, 0)
                output.newLine(depth: depth)
                output.append(byte)
                index += 1
            case UInt8(ascii: ","):
                output.append(byte)
                output.newLine(depth: depth)
                index += 1
            case UInt8(ascii: ":"):
                output.append(byte)
                output.append(0x20)
                index += 1
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                // A line comment keeps its line.
                var end = index
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                if !output.atLineStart { output.append(0x20) }
                output.append(bytes[index..<end])
                output.newLine(depth: depth)
                index = end
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                var end = index + 2
                while end + 1 < bytes.count, !(bytes[end] == UInt8(ascii: "*") && bytes[end + 1] == UInt8(ascii: "/")) {
                    end += 1
                }
                end = min(end + 2, bytes.count)
                if !output.atLineStart { output.append(0x20) }
                output.append(bytes[index..<end])
                index = end
            default:
                // A number, a literal (true, null, …) or anything else, up to the next delimiter.
                var end = index + 1
                while end < bytes.count, !isSpace(bytes[end]),
                      !"{}[],:\"'/".utf8.contains(bytes[end]) { end += 1 }
                output.append(bytes[index..<end])
                index = end
            }
            if output.isOverLimit { return nil }
        }
        return output.text
    }

    /// XML, an element a line: an element holding only text stays on one line, text
    /// between elements gets lines of its own, whitespace between elements goes;
    /// comments, CDATA, processing instructions and the DOCTYPE are kept whole.
    static func xml(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        let tokens = xmlTokens(bytes)
        var output = Output(limit: outputLimit(bytes.count))
        var depth = 0, index = 0
        func line(_ ranges: Range<Int>...) {
            output.newLine(depth: depth)
            for range in ranges { output.append(bytes[range]) }
        }
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .start:
                if index + 2 < tokens.count, tokens[index + 1].kind == .text, tokens[index + 2].kind == .end {
                    // <name>text</name>, the text as it is.
                    line(token.range, tokens[index + 1].range, tokens[index + 2].range)
                    index += 3
                    continue
                }
                if index + 1 < tokens.count, tokens[index + 1].kind == .end {
                    line(token.range, tokens[index + 1].range)
                    index += 2
                    continue
                }
                line(token.range)
                depth += 1
            case .end:
                depth = max(depth - 1, 0)
                line(token.range)
            case .text:
                // Text among elements, without the whitespace around it.
                var range = token.range
                while !range.isEmpty, bytes[range.lowerBound] <= 0x20 { range = range.dropFirst() }
                while !range.isEmpty, bytes[range.upperBound - 1] <= 0x20 { range = range.dropLast() }
                if !range.isEmpty { line(range) }
            case .other:
                line(token.range)
            }
            if output.isOverLimit { return nil }
            index += 1
        }
        return output.text
    }

    private struct XMLToken {
        enum Kind { case start, end, text, other }
        let kind: Kind
        let range: Range<Int>
    }

    /// The text cut into tags and text; a start tag's `>` found past quoted values.
    /// What is not a proper tag (a lone `<`, an unterminated comment) is text. The
    /// looking ahead has a budget: a file of unterminated tags cannot take time in
    /// proportion to its size squared (the rest is text once it is spent).
    private static func xmlTokens(_ bytes: [UInt8]) -> [XMLToken] {
        var tokens: [XMLToken] = []
        var index = 0, textStart = 0
        var budget = bytes.count * 8 + 1_000_000
        /// Terminators known to be missing from some place on (so from any later one).
        var missing: Set<String> = []
        func starts(with prefix: String, at position: Int) -> Bool {
            let prefix = Array(prefix.utf8)
            return position + prefix.count <= bytes.count && bytes[position..<position + prefix.count].elementsEqual(prefix)
        }
        /// The end of `terminator` from `position` on, or nil.
        func find(_ terminator: String, from position: Int) -> Int? {
            guard !missing.contains(terminator) else { return nil }
            let pattern = Array(terminator.utf8)
            var position = position
            while position + pattern.count <= bytes.count, budget > 0 {
                budget -= 1
                if bytes[position] == pattern[0], bytes[position..<position + pattern.count].elementsEqual(pattern) {
                    return position + pattern.count
                }
                position += 1
            }
            if budget > 0 { missing.insert(terminator) }
            return nil
        }
        /// Past the `>` closing a tag, skipping quoted values (and, in a declaration,
        /// the DOCTYPE's internal subset in brackets).
        func tagEnd(from position: Int, declaration: Bool = false) -> Int? {
            var position = position, quote: UInt8?, brackets = 0
            while position < bytes.count, budget > 0 {
                budget -= 1
                let byte = bytes[position]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if declaration, byte == UInt8(ascii: "[") {
                    brackets += 1
                } else if declaration, byte == UInt8(ascii: "]") {
                    brackets = max(brackets - 1, 0)
                } else if byte == UInt8(ascii: ">"), brackets == 0 {
                    return position + 1
                } else if byte == UInt8(ascii: "<"), brackets == 0 {
                    return nil
                }
                position += 1
            }
            return nil
        }
        func isNameStart(_ byte: UInt8) -> Bool {
            byte >= 0x80 || (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":")
        }
        while index < bytes.count, budget > 0 {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            var end: Int?
            var kind = XMLToken.Kind.other
            if starts(with: "<!--", at: index) {
                end = find("-->", from: index + 4)
            } else if starts(with: "<![CDATA[", at: index) {
                end = find("]]>", from: index + 9)
            } else if starts(with: "<?", at: index) {
                end = find("?>", from: index + 2)
            } else if starts(with: "<!", at: index) {
                end = tagEnd(from: index + 2, declaration: true)
            } else if starts(with: "</", at: index) {
                end = tagEnd(from: index + 2)
                kind = .end
            } else if index + 1 < bytes.count, isNameStart(bytes[index + 1]) {
                end = tagEnd(from: index + 1)
                if let close = end {
                    kind = bytes[close - 2] == UInt8(ascii: "/") ? .other : .start
                }
            }
            guard let close = end else {
                index += 1
                continue
            }
            if textStart < index { tokens.append(XMLToken(kind: .text, range: textStart..<index)) }
            tokens.append(XMLToken(kind: kind, range: index..<close))
            index = close
            textStart = close
        }
        if textStart < bytes.count { tokens.append(XMLToken(kind: .text, range: textStart..<bytes.count)) }
        return tokens
    }

    /// The formatted text, a line at a time; a line left empty is taken back.
    private struct Output {
        private var bytes: [UInt8] = []
        private var lineStart = 0
        let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        var atLineStart: Bool { bytes[lineStart...].allSatisfy { $0 == 0x20 } }
        var isOverLimit: Bool { bytes.count > limit }

        mutating func append(_ byte: UInt8) {
            bytes.append(byte)
        }

        mutating func append(_ slice: ArraySlice<UInt8>) {
            bytes.append(contentsOf: slice)
        }

        /// Starts a line indented for `depth` (the current one again when it is empty).
        mutating func newLine(depth: Int) {
            if atLineStart {
                bytes.removeSubrange(lineStart...)
            } else {
                bytes.append(0x0A)
                lineStart = bytes.count
            }
            bytes.append(contentsOf: repeatElement(0x20, count: min(depth, CodeFormatter.maxDepth) * CodeFormatter.indent))
        }

        var text: String {
            var bytes = bytes
            while bytes.last == 0x20 || bytes.last == 0x0A { bytes.removeLast() }
            // The first line was started empty.
            let start = bytes.firstIndex { $0 != 0x0A } ?? bytes.endIndex
            return String(decoding: bytes[start...], as: UTF8.self) + "\n"
        }
    }
}
