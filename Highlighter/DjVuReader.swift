import Foundation

/// DjVu documents (one page, or bundled pages): the pages' sizes (INFO) and their
/// hidden text layer (TXTz, compressed with BZZ, or TXTa), read as the book's text,
/// a page after another. The page pictures themselves are drawn by DjVuLibre's
/// ddjvu when it is installed (see OriCmd's DjVuPages). Indirect documents (pages
/// in other files) are said so. Every read is bounds-checked.
final class DjVuReader {
    private let builder: BookBuilder
    /// The document as it came (big scanned books are not copied).
    private let data: Data
    /// Text layers decompressed, all pages together (BZZ expands small chunks a lot).
    private static let maxDecoded = 64 * 1024 * 1024
    private static let maxPages = 100_000

    init(_ builder: BookBuilder, _ data: Data) {
        self.builder = builder
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    /// A page: its size and where its text layer is (decompressed only when its
    /// turn comes, while the budget lasts).
    private struct Page {
        var width = 0, height = 0, dpi = 300
        var text: (range: Range<Int>, compressed: Bool)?
    }

    func read() {
        guard data.count >= 16, Array(data[0..<4]) == Array("AT&T".utf8), tag(at: 4) == "FORM",
              let size = uint32(at: 8), let kind = tag(at: 12) else { return }
        let end = min(12 + Int(size), data.count)
        var pages: [Page] = []
        switch kind {
        case "DJVU":
            pages.append(page(from: 16, to: end))
        case "DJVM":
            var position = 16
            var bundled = true
            while position + 8 <= end, pages.count < Self.maxPages {
                guard let id = tag(at: position), let length = uint32(at: position + 4) else { break }
                let body = position + 8, bodyEnd = min(body + Int(length), end)
                if id == "DIRM", body < end { bundled = data[body] & 0x80 != 0 }
                if id == "FORM", tag(at: body) == "DJVU" { pages.append(page(from: body + 4, to: bodyEnd)) }
                position = body + Int(length) + (Int(length) & 1)
            }
            if !bundled {
                builder.notice = "djvu-indirect"
                return
            }
        default:
            return
        }
        builder.pages = pages.map { ($0.width, $0.height, $0.dpi) }
        var decodedLeft = Self.maxDecoded
        var hasText = false
        for (index, page) in pages.enumerated() {
            guard decodedLeft > 0, !builder.isFull else { break }
            guard let chunk = page.text, let text = layer(chunk, budget: &decodedLeft), !text.isEmpty else { continue }
            hasText = true
            if pages.count > 1 {
                builder.begin(.subtitle)
                builder.text("— \(index + 1) —")
                builder.end()
            }
            // Regions, paragraphs and columns end paragraphs; lines flow on. A
            // paragraph at a time, up to what the book takes.
            var rest = Substring(String(decoding: text, as: UTF8.self))
            let separators: Set<Character> = ["\u{1D}", "\u{1F}", "\u{0B}", "\u{0C}"]
            while !rest.isEmpty, !builder.isFull {
                let paragraph = rest.prefix { !separators.contains($0) }
                rest = rest[paragraph.endIndex...].drop { separators.contains($0) }
                guard !paragraph.isEmpty else { continue }
                builder.begin(.paragraph)
                builder.text(String(paragraph))
                builder.end()
            }
        }
        if !hasText { builder.notice = "djvu-no-text" }
    }

    /// A page's text, decompressed (TXTz) or as it is (TXTa), charged to `budget`:
    /// what decompressing cost, damaged layers too (many pages of layers that
    /// expand past the limit would otherwise take the service's time for nothing).
    private func layer(_ chunk: (range: Range<Int>, compressed: Bool), budget: inout Int) -> [UInt8]? {
        let bytes = [UInt8](data[chunk.range])
        budget -= bytes.count
        guard chunk.compressed else { return Self.layerText(bytes) }
        var work = 0
        let decoded = BZZ.decode(bytes, work: &work)
        budget -= work
        return decoded.flatMap(Self.layerText)
    }

    /// A page's INFO and text chunks, between `start` and `end`.
    private func page(from start: Int, to end: Int) -> Page {
        var page = Page()
        var position = start
        while position + 8 <= end {
            guard let id = tag(at: position), let length = uint32(at: position + 4) else { break }
            let body = position + 8
            guard body + Int(length) <= end else { break }
            switch id {
            case "INFO" where length >= 10:
                page.width = Int(uint16(at: body) ?? 0)
                page.height = Int(uint16(at: body + 2) ?? 0)
                let dpi = Int(data[body + 6]) | Int(data[body + 7]) << 8
                if (25...6000).contains(dpi) { page.dpi = dpi }
                // Turned a quarter (orientation 5 or 6): shown the other way round.
                if [5, 6].contains(data[body + 9] & 7) { swap(&page.width, &page.height) }
            case "TXTz", "TXTa":
                // The last text layer of the page counts.
                page.text = (body..<(body + Int(length)), id == "TXTz")
            default:
                break
            }
            position = body + Int(length) + (Int(length) & 1)
        }
        return page
    }

    /// The text of a text layer: its length (3 bytes) and UTF-8; the zones that
    /// follow are left out.
    private static func layerText(_ layer: [UInt8]) -> [UInt8]? {
        guard layer.count >= 3 else { return nil }
        let length = Int(layer[0]) << 16 | Int(layer[1]) << 8 | Int(layer[2])
        guard length <= layer.count - 3 else { return nil }
        return Array(layer[3..<(3 + length)])
    }

    private func tag(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }
}

/// DjVu's ZP arithmetic decoder, as DjVuLibre's ZPCodec (in DjVu compatibility
/// mode): its state is kept to 16 bits where the original truncates. Past the end
/// of its data it reads 0xFF, up to 25 times, then stops (`isAtEnd`).
struct ZPDecoder {
    private let input: [UInt8]
    private var position = 0
    private var a: UInt32 = 0
    private var code: UInt32 = 0
    private var fence: UInt32 = 0
    private var buffer: UInt32 = 0
    private var scount = 0
    private var delay = 25
    private(set) var isAtEnd = false
    private static let ffzt: [UInt32] = (0..<256).map { value in
        var count: UInt32 = 0, bits = value
        while bits & 0x80 != 0 {
            count += 1
            bits <<= 1
        }
        return count
    }

    init(_ input: [UInt8]) {
        self.input = input
        code = UInt32(nextByte()) << 8 | UInt32(nextByte())
        preload()
        fence = code >= 0x8000 ? 0x7FFF : code
    }

    private mutating func nextByte() -> UInt8 {
        guard position < input.count else { return 0xFF }
        defer { position += 1 }
        return input[position]
    }

    private mutating func preload() {
        while scount <= 24 {
            var byte: UInt8 = 0xFF
            if position < input.count {
                byte = input[position]
                position += 1
            } else {
                delay -= 1
                if delay < 1 { isAtEnd = true }
            }
            buffer = buffer &<< 8 | UInt32(byte)
            scount += 8
        }
    }

    private static func ffz(_ x: UInt32) -> Int {
        Int(x >= 0xFF00 ? ffzt[Int(x & 0xFF)] + 8 : ffzt[Int((x >> 8) & 0xFF)])
    }

    /// A bit with the adaptive context `context`.
    mutating func decode(_ context: inout UInt8) -> Int {
        let z = a + Self.p[Int(context)]
        if z <= fence {
            a = z
            return Int(context & 1)
        }
        return decodeSub(&context, z)
    }

    /// A bit with no context (probability one half).
    mutating func decode() -> Int {
        decodeSimple(mps: 0, 0x8000 + (a >> 1))
    }

    private mutating func decodeSub(_ context: inout UInt8, _ zIn: UInt32) -> Int {
        let bit = Int(context & 1)
        var z = zIn
        let d = 0x6000 + ((z + a) >> 2)
        if z > d { z = d }
        if z > code {
            z = 0x10000 - z
            a += z
            code += z
            context = Self.dn[Int(context)]
            renormalize(lps: true)
            return bit ^ 1
        }
        if a >= Self.m[Int(context)] { context = Self.up[Int(context)] }
        scount -= 1
        a = (z << 1) & 0xFFFF
        code = ((code << 1) & 0xFFFF) | ((buffer >> UInt32(scount)) & 1)
        if scount < 16 { preload() }
        fence = code >= 0x8000 ? 0x7FFF : code
        return bit
    }

    private mutating func decodeSimple(mps: Int, _ zIn: UInt32) -> Int {
        var z = zIn
        if z > code {
            z = 0x10000 - z
            a += z
            code += z
            renormalize(lps: true)
            return mps ^ 1
        }
        scount -= 1
        a = (z << 1) & 0xFFFF
        code = ((code << 1) & 0xFFFF) | ((buffer >> UInt32(scount)) & 1)
        if scount < 16 { preload() }
        fence = code >= 0x8000 ? 0x7FFF : code
        return mps
    }

    /// After the unlikely bit: shifted by the leading ones of `a`.
    private mutating func renormalize(lps: Bool) {
        let shift = Self.ffz(a)
        scount -= shift
        a = (a << UInt32(shift)) & 0xFFFF
        code = ((code << UInt32(shift)) & 0xFFFF) | ((buffer >> UInt32(scount)) & ((1 << UInt32(shift)) - 1))
        if scount < 16 { preload() }
        fence = code >= 0x8000 ? 0x7FFF : code
    }
}

/// DjVu's BZZ compression (DjVuLibre's BSByteStream): blocks of a Burrows–Wheeler
/// transform whose bytes are coded by move-to-front ranks with the ZP coder. At
/// most 16 MB come out; a damaged block stops the reading.
enum BZZ {
    /// The decompressed data (at most 16 MB); nil when damaged or larger.
    static func decode(_ input: [UInt8]) -> [UInt8]? {
        var work = 0
        return decode(input, work: &work)
    }

    /// Also counts in `work` the size of every block started, whether or not the
    /// data turns out whole: what decoding it cost.
    static func decode(_ input: [UInt8], work: inout Int) -> [UInt8]? {
        var zp = ZPDecoder(input)
        var contexts = [UInt8](repeating: 0, count: 300)
        var output: [UInt8] = []
        while true {
            guard let block = decodeBlock(&zp, &contexts, work: &work) else { return nil }
            if block.isEmpty { break }
            output += block.dropLast()
            guard output.count <= 16 * 1024 * 1024, !zp.isAtEnd else { return output.count <= 16 * 1024 * 1024 ? output : nil }
        }
        return output
    }

    private static func raw(_ zp: inout ZPDecoder, bits: Int) -> Int {
        var n = 1
        let m = 1 << bits
        while n < m { n = n << 1 | zp.decode() }
        return n - m
    }

    private static func binary(_ zp: inout ZPDecoder, _ contexts: inout [UInt8], _ start: Int, bits: Int) -> Int {
        var n = 1
        let m = 1 << bits
        while n < m { n = n << 1 | zp.decode(&contexts[start + n - 1]) }
        return n - m
    }

    /// One block (empty at the end of the stream); nil when damaged.
    private static func decodeBlock(_ zp: inout ZPDecoder, _ contexts: inout [UInt8], work: inout Int) -> [UInt8]? {
        let size = raw(&zp, bits: 24)
        if size == 0 { return [] }
        guard size <= 4096 * 1024, !zp.isAtEnd else { return nil }
        work += size
        var shift = 0
        if zp.decode() != 0 {
            shift += 1
            if zp.decode() != 0 { shift += 1 }
        }
        var mtf = [UInt8](0...255)
        var frequencies = [UInt32](repeating: 0, count: 4)
        var add: UInt32 = 4
        var data = [UInt8](repeating: 0, count: size)
        var rank = 3
        var marker = -1
        for index in 0..<size {
            if zp.isAtEnd { return nil }
            let context = min(2, rank)
            var found: Int?
            if zp.decode(&contexts[context]) != 0 {
                found = 0
            } else if zp.decode(&contexts[3 + context]) != 0 {
                found = 1
            } else {
                // Ranks 2–3, 4–7 … 128–255, each group behind its own flag.
                var base = 6
                for bits in 1...7 {
                    if zp.decode(&contexts[base]) != 0 {
                        found = (1 << bits) + binary(&zp, &contexts, base + 1, bits: bits)
                        break
                    }
                    base += 1 + (1 << bits) - 1
                }
            }
            guard let found else {
                rank = 256
                data[index] = 0
                marker = index
                continue
            }
            rank = found
            data[index] = mtf[rank]
            // Move to front by the empirical frequencies.
            add = add &+ (add >> UInt32(shift))
            if add > 0x1000_0000 {
                add >>= 24
                for k in 0..<4 { frequencies[k] >>= 24 }
            }
            var frequency = add
            if rank < 4 { frequency = frequency &+ frequencies[rank] }
            var k = rank
            while k >= 4 {
                mtf[k] = mtf[k - 1]
                k -= 1
            }
            while k > 0, frequency >= frequencies[k - 1] {
                mtf[k] = mtf[k - 1]
                frequencies[k] = frequencies[k - 1]
                k -= 1
            }
            mtf[k] = data[index]
            if k < 4 { frequencies[k] = frequency }
        }
        guard marker >= 1, marker < size else { return nil }
        // Undo the sort.
        var positions = [UInt32](repeating: 0, count: size)
        var counts = [Int](repeating: 0, count: 256)
        for index in 0..<size where index != marker {
            let byte = Int(data[index])
            positions[index] = UInt32(byte) << 24 | UInt32(counts[byte] & 0xFF_FFFF)
            counts[byte] += 1
        }
        var last = 1
        for byte in 0..<256 {
            let count = counts[byte]
            counts[byte] = last
            last += count
        }
        var index = 0
        last = size - 1
        while last > 0 {
            let value = positions[index]
            let byte = Int(value >> 24)
            last -= 1
            data[last] = UInt8(byte)
            index = counts[byte] + Int(value & 0xFF_FFFF)
            guard index < size else { return nil }
        }
        guard index == marker else { return nil }
        return data
    }
}
