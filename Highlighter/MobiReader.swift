import Foundation

/// Mobipocket and Kindle books (.mobi, .azw, .azw3, .prc) and plain PalmDOC texts:
/// the Palm database's records, the book header (PalmDOC, MOBI, EXTH), the text
/// records without their trailing entries, uncompressed or PalmDOC (LZ77) or
/// HUFF/CDIC compressed, then read as HTML (`HTMLBookReader`) with its pictures from
/// the image records. KF8 (AZW3) text is its first flow. Books protected by DRM
/// can't be read: the notice says so. Every read is bounds-checked; the text is
/// at most 64 MB.
final class MobiReader {
    private let builder: BookBuilder
    private let data: Data
    private var records: [Range<Int>] = []
    private static let maxText = 64 * 1024 * 1024
    private static let noIndex = 0xFFFF_FFFF

    init(_ builder: BookBuilder, _ data: Data) {
        self.builder = builder
        self.data = data
    }

    func read() {
        guard readRecords(), let type = string(at: 60, length: 8) else { return }
        if type == "TEXtREAd" { return readPalmDOC() }
        guard type == "BOOKMOBI", let header = records.first, let book = BookHeader(self, record: header) else { return }
        if book.encryption != 0 {
            builder.notice = "drm"
            builder.title = book.title
            builder.author = book.author
            return
        }
        guard var text = decompressedText(book, base: 0) else { return }
        // KF8 keeps its HTML in the first flow; stylesheets and the like follow.
        if book.version >= 8, book.fdst != Self.noIndex, let range = record(book.fdst),
           string(at: range.lowerBound, length: 4) == "FDST",
           let tableStart = uint32(at: range.lowerBound + 4), let count = uint32(at: range.lowerBound + 8), count > 0,
           let end = uint32(at: range.lowerBound + Int(tableStart) + 4), Int(end) <= text.count {
            text = Array(text.prefix(Int(end)))
        }
        builder.title = book.title
        builder.author = book.author
        let decoded = book.encoding == 65001
            ? String(decoding: text, as: UTF8.self)
            : String(data: Data(text), encoding: .windowsCP1252) ?? String(decoding: text, as: UTF8.self)
        var pictures: [Int: Int] = [:]
        func picture(_ number: Int) -> Int? {
            guard number >= 0, book.firstImage != Self.noIndex else { return nil }
            let recordIndex = book.firstImage + number
            if let index = pictures[recordIndex] { return index }
            guard let range = record(recordIndex), let index = builder.addImage(data[range]) else { return nil }
            pictures[recordIndex] = index
            return index
        }
        if let cover = book.cover, let index = picture(cover) {
            builder.image(index)
            builder.separator()
        }
        HTMLBookReader(builder).read(decoded) { source in
            // MOBI 6: recindex (from 1); KF8: kindle:embed:XXXX (base 32, from 1).
            if source.hasPrefix("recindex:"), let number = Int(source.dropFirst(9)) {
                return picture(number - 1)
            }
            if let range = source.range(of: "kindle:embed:") {
                let digits = source[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
                guard let number = Int(digits, radix: 32) else { return nil }
                return picture(number - 1)
            }
            return nil
        }
    }

    // MARK: - Records

    private func readRecords() -> Bool {
        guard let count = uint16(at: 76), count > 0 else { return false }
        var offsets: [Int] = []
        for index in 0..<Int(count) {
            guard let offset = uint32(at: 78 + index * 8) else { return false }
            offsets.append(Int(offset))
        }
        offsets.append(data.count)
        for index in 0..<Int(count) {
            let start = offsets[index], end = offsets[index + 1]
            // Out of order or outside the file: nothing is read.
            guard start >= 78, start <= end, end <= data.count else { return false }
            records.append(start..<end)
        }
        return true
    }

    private func record(_ index: Int) -> Range<Int>? {
        records.indices.contains(index) ? records[index] : nil
    }

    // MARK: - The book header

    private struct BookHeader {
        var compression = 0, textRecords = 0, encryption = 0
        var encoding = 1252, version = 6, firstImage = MobiReader.noIndex, extraFlags = 0
        var huffmanRecord = MobiReader.noIndex, huffmanCount = 0, fdst = MobiReader.noIndex
        var title = "", author = ""
        var cover: Int?

        init?(_ reader: MobiReader, record: Range<Int>) {
            let at = record.lowerBound
            guard let compression = reader.uint16(at: at), let textRecords = reader.uint16(at: at + 8),
                  let encryption = reader.uint16(at: at + 12) else { return nil }
            self.compression = Int(compression)
            self.textRecords = Int(textRecords)
            self.encryption = Int(encryption)
            guard reader.string(at: at + 16, length: 4) == "MOBI", let headerLength = reader.uint32(at: at + 20),
                  at + 16 + Int(headerLength) <= record.upperBound else { return }
            let field = { (offset: Int) -> Int? in
                offset + 4 <= 16 + Int(headerLength) ? reader.uint32(at: at + offset).map(Int.init) : nil
            }
            encoding = field(0x1C) ?? 1252
            version = field(0x24) ?? 6
            firstImage = field(0x6C) ?? MobiReader.noIndex
            huffmanRecord = field(0x70) ?? MobiReader.noIndex
            huffmanCount = field(0x74) ?? 0
            if headerLength >= 0xE4 { extraFlags = (field(0xF0) ?? 0) & 0xFFFF }
            if version >= 8 { fdst = field(0xC0) ?? MobiReader.noIndex }
            if let offset = field(0x54), let length = field(0x58), length < 1024,
               at + offset + length <= record.upperBound {
                title = reader.text(at + offset, length, encoding: encoding)
            }
            // EXTH: the author (100), the title (503), the cover (201, from the first image).
            guard let flags = field(0x80), flags & 0x40 != 0 else { return }
            let exth = at + 16 + Int(headerLength)
            guard reader.string(at: exth, length: 4) == "EXTH", let count = reader.uint32(at: exth + 8) else { return }
            var position = exth + 12
            for _ in 0..<min(Int(count), 1000) {
                guard let kind = reader.uint32(at: position), let length = reader.uint32(at: position + 4),
                      length >= 8, position + Int(length) <= record.upperBound else { break }
                let value = position + 8, valueLength = Int(length) - 8
                switch kind {
                case 100 where author.isEmpty: author = reader.text(value, min(valueLength, 1024), encoding: encoding)
                case 503: title = reader.text(value, min(valueLength, 1024), encoding: encoding)
                case 201 where valueLength >= 4: cover = reader.uint32(at: value).map(Int.init)
                default: break
                }
                position += Int(length)
            }
        }
    }

    // MARK: - Text

    private func decompressedText(_ book: BookHeader, base: Int) -> [UInt8]? {
        var huffman: HuffCdic?
        if book.compression == 17480 {
            var tables: [Data] = []
            for index in 0..<min(book.huffmanCount, 256) {
                guard let range = record(book.huffmanRecord + index) else { return nil }
                tables.append(data[range])
            }
            huffman = HuffCdic(tables)
            guard huffman != nil else { return nil }
        }
        var text: [UInt8] = []
        for index in 1...max(book.textRecords, 1) {
            guard book.textRecords > 0, let range = record(base + index) else { break }
            let bytes = [UInt8](data[range])
            let size = bytes.count - trailingSize(bytes, flags: book.extraFlags)
            guard size >= 0 else { return nil }
            let body = Array(bytes[0..<size])
            let piece: [UInt8]?
            switch book.compression {
            case 1: piece = body
            case 2: piece = Self.palmDOC(body)
            case 17480: piece = huffman?.unpack(body)
            default: piece = nil
            }
            guard let piece else { return nil }
            text += piece
            if text.count > Self.maxText { break }
        }
        return text
    }

    /// The trailing entries a record's flags announce: sizes stored backwards at
    /// its end (each flag past the first), and the overlapping multibyte character.
    private func trailingSize(_ bytes: [UInt8], flags: Int) -> Int {
        var size = 0
        var bits = flags >> 1
        while bits != 0 {
            if bits & 1 != 0 {
                var value = 0, shift = 0, end = bytes.count - size
                while end > 0 {
                    let byte = Int(bytes[end - 1])
                    value |= (byte & 0x7F) << shift
                    shift += 7
                    end -= 1
                    if byte & 0x80 != 0 || shift >= 28 { break }
                }
                size += value
                if size > bytes.count { return bytes.count }
            }
            bits >>= 1
        }
        if flags & 1 != 0, bytes.count - size > 0 {
            size += Int(bytes[bytes.count - size - 1] & 0x3) + 1
        }
        return min(size, bytes.count)
    }

    /// PalmDOC compression: literals, runs of literals, space pairs, and copies of
    /// up to ten bytes from up to 2047 bytes back.
    static func palmDOC(_ input: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        var index = 0
        while index < input.count {
            let byte = input[index]
            index += 1
            switch byte {
            case 0, 0x09...0x7F:
                output.append(byte)
            case 0x01...0x08:
                let count = Int(byte)
                guard index + count <= input.count else { return nil }
                output += input[index..<(index + count)]
                index += count
            case 0xC0...0xFF:
                output.append(0x20)
                output.append(byte ^ 0x80)
            default:
                guard index < input.count else { return nil }
                let pair = Int(byte) << 8 | Int(input[index])
                index += 1
                let distance = (pair >> 3) & 0x07FF, length = (pair & 7) + 3
                guard distance > 0, distance <= output.count else { return nil }
                for _ in 0..<length { output.append(output[output.count - distance]) }
            }
            if output.count > 1 << 20 { return nil }
        }
        return output
    }

    /// A PalmDOC e-text: plain text in records, a paragraph a line.
    private func readPalmDOC() {
        guard let header = records.first, let compression = uint16(at: header.lowerBound),
              let count = uint16(at: header.lowerBound + 8) else { return }
        var text: [UInt8] = []
        for index in 1...max(Int(count), 1) {
            guard count > 0, let range = record(index) else { break }
            let bytes = [UInt8](data[range])
            guard let piece = compression == 2 ? Self.palmDOC(bytes) : bytes else { return }
            text += piece
            if text.count > Self.maxText { break }
        }
        builder.title = string(at: 0, length: 32)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
        let decoded = String(data: Data(text), encoding: .utf8)
            ?? String(data: Data(text), encoding: .windowsCP1252) ?? ""
        for line in decoded.split(whereSeparator: \.isNewline) {
            builder.begin(.paragraph)
            builder.text(String(line))
        }
        builder.end()
    }

    // MARK: - Reading bytes

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func string(at offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
        return String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + length], as: UTF8.self)
    }

    func text(_ offset: Int, _ length: Int, encoding: Int) -> String {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return "" }
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + length]
        return (encoding == 65001 ? String(data: bytes, encoding: .utf8) : String(data: bytes, encoding: .windowsCP1252))
            ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// Mobipocket's Huffman compression: a HUFF record (code lengths and ranges) and
/// CDIC records (the phrases, themselves compressed or not). A phrase that refers
/// back to itself, or nests too deep, stops the reading.
struct HuffCdic {
    private var table: [(length: Int, terminal: Bool, maxCode: UInt64)] = []
    private var minCodes: [UInt64] = [0]
    private var maxCodes: [UInt64] = [0]
    private var phrases: [(bytes: [UInt8], done: Bool)] = []
    private var unpacking: Set<Int> = []
    private var produced = 0

    init?(_ records: [Data]) {
        guard let huff = records.first.map({ [UInt8]($0) }), huff.count >= 24,
              Array(huff[0..<8]) == Array("HUFF".utf8) + [0, 0, 0, 0x18] else { return nil }
        func be32(_ bytes: [UInt8], _ offset: Int) -> UInt64? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard let first = be32(huff, 8).map(Int.init), let second = be32(huff, 12).map(Int.init) else { return nil }
        for index in 0..<256 {
            guard let value = be32(huff, first + index * 4) else { return nil }
            let length = Int(value & 0x1F), terminal = value & 0x80 != 0
            guard length > 0, length <= 32 else { return nil }
            let maxCode = ((value >> 8) + 1) << UInt64(32 - length) &- 1
            table.append((length, terminal, maxCode))
        }
        for length in 1...32 {
            guard let low = be32(huff, second + (length - 1) * 8), let high = be32(huff, second + (length - 1) * 8 + 4)
            else { return nil }
            minCodes.append(low << UInt64(32 - length))
            maxCodes.append(((high + 1) << UInt64(32 - length)) &- 1)
        }
        for record in records.dropFirst() {
            let cdic = [UInt8](record)
            guard cdic.count >= 16, Array(cdic[0..<8]) == Array("CDIC".utf8) + [0, 0, 0, 0x10],
                  let count = be32(cdic, 8), let bits = be32(cdic, 12), bits < 32 else { return nil }
            let entries = min(1 << Int(bits), max(Int(count) - phrases.count, 0))
            for entry in 0..<entries {
                guard entry * 2 + 18 <= cdic.count else { return nil }
                let offset = Int(cdic[16 + entry * 2]) << 8 | Int(cdic[17 + entry * 2])
                guard 16 + offset + 2 <= cdic.count else { return nil }
                let header = Int(cdic[16 + offset]) << 8 | Int(cdic[17 + offset])
                let length = header & 0x7FFF
                guard 18 + offset + length <= cdic.count else { return nil }
                phrases.append((Array(cdic[(18 + offset)..<(18 + offset + length)]), header & 0x8000 != 0))
            }
        }
    }

    mutating func unpack(_ input: [UInt8], depth: Int = 0) -> [UInt8]? {
        guard depth < 32 else { return nil }
        let padded = input + [UInt8](repeating: 0, count: 8)
        func word(_ position: Int) -> UInt64 {
            padded[position..<(position + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }
        var bitsLeft = input.count * 8
        var position = 0
        var window = word(0)
        var available = 32
        var output: [UInt8] = []
        while true {
            if available <= 0 {
                position += 4
                guard position + 8 <= padded.count else { break }
                window = word(position)
                available += 32
            }
            let code = (window >> UInt64(available)) & 0xFFFF_FFFF
            var (length, terminal, maxCode) = table[Int(code >> 24)]
            if !terminal {
                while length < 32, code < minCodes[length] { length += 1 }
                maxCode = maxCodes[length]
            }
            available -= length
            bitsLeft -= length
            if bitsLeft < 0 { break }
            let index = Int(truncatingIfNeeded: (maxCode &- code) >> UInt64(32 - length))
            guard phrases.indices.contains(index) else { return nil }
            if !phrases[index].done {
                // A phrase compressed itself: unpacked once, kept.
                guard !unpacking.contains(index) else { return nil }
                unpacking.insert(index)
                guard let phrase = unpack(phrases[index].bytes, depth: depth + 1) else { return nil }
                unpacking.remove(index)
                phrases[index] = (phrase, true)
            }
            output += phrases[index].bytes
            produced += phrases[index].bytes.count
            if output.count > 1 << 20 || produced > 256 * 1024 * 1024 { return nil }
        }
        return output
    }
}
