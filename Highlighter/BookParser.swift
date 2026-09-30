import CoreGraphics
import Foundation
import ImageIO

/// Reads e-books for the Lister's book view: FB2 (and .fb2.zip) and EPUB. It runs
/// in this locked-down process, as the books are strangers' data; the result is
/// plain data (see `BookBuilder`) that OriCmd checks before showing it, pictures
/// included as plain pixels, so no picture is decoded in OriCmd.
enum BookParser {
    static func parse(_ data: Data, format: String) -> Data? {
        let builder = BookBuilder()
        switch format {
        case "fb2":
            FB2Reader(builder).read(data)
        case "fb2.zip":
            guard var zip = ZipReader(data),
                  let entry = zip.entries.first(where: { $0.name.lowercased().hasSuffix(".fb2") }),
                  let book = zip.contents(of: entry) else { return nil }
            FB2Reader(builder).read(book)
        case "epub":
            guard var zip = ZipReader(data) else { return nil }
            EPUBReader(builder).read(&zip)
        case "mobi":
            MobiReader(builder, data).read()
        case "djvu":
            DjVuReader(builder, data).read()
        default:
            return nil
        }
        return builder.isEmpty ? nil : builder.encoded()
    }
}

// MARK: - The book

/// Blocks of styled text and pictures, written out as "OBK1", then the title, the
/// author, the notice, the block count and the blocks (kind, level, and runs of
/// style and text, or a picture's index), the picture count and the pictures
/// (width, height, RGBA bytes), and for a DjVu document its pages (count, then
/// width, height, dpi each); counts UInt32 little-endian, texts as their UTF-8
/// length and bytes.
final class BookBuilder {
    enum Kind: UInt8 {
        case paragraph = 0, heading, quote, verse, image, separator, note, preformatted, subtitle, signature
    }

    struct Style: OptionSet {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let code = Style(rawValue: 4)
        static let superscript = Style(rawValue: 8)
        static let `subscript` = Style(rawValue: 16)
        static let strikethrough = Style(rawValue: 32)
    }

    static let maxBlocks = 1_000_000
    static let maxRuns = 4_000_000
    /// Longer text would take the text view long to lay out.
    static let maxTextBytes = 24 * 1024 * 1024
    static let maxImages = 1000
    static let maxImageBytes = 160 * 1024 * 1024
    static let maxImageSide = 1400

    private struct Block {
        var kind: Kind
        var level: UInt8
        var runs: [(Style, String)] = []
        var image = 0
    }

    var title = ""
    var author = ""
    /// A DjVu document's pages (pixels and resolution), for drawing them.
    var pages: [(width: Int, height: Int, dpi: Int)] = []
    /// Said instead of or before the book (a book protected by DRM, say).
    var notice = ""
    private var blocks: [Block] = []
    private var images: [(width: Int, height: Int, pixels: Data)] = []
    private var runCount = 0
    private var textBytes = 0
    private var imageBytes = 0

    /// The paragraph being written, and whether its last text ended with a space.
    private var open: Block?
    private var endsWithSpace = true
    private var keepsSpaces = false

    var isEmpty: Bool { blocks.isEmpty && open == nil && notice.isEmpty && pages.isEmpty }

    /// Starts a paragraph of `kind` (ending one still open).
    func begin(_ kind: Kind, level: Int = 0) {
        end()
        open = Block(kind: kind, level: UInt8(clamping: level))
        endsWithSpace = true
        keepsSpaces = kind == .preformatted
    }

    /// Text in a paragraph (one of `kind` is started when none is open); runs of
    /// white space become one space unless the paragraph keeps them.
    func text(_ text: String, style: Style = [], kind: Kind = .paragraph) {
        if open == nil { begin(kind) }
        guard open != nil, runCount < Self.maxRuns, textBytes < Self.maxTextBytes else { return }
        var piece = ""
        if keepsSpaces {
            piece = text
        } else {
            for character in text {
                if character.isWhitespace && character != "\u{2028}" {
                    if !endsWithSpace { piece.append(" ") }
                    endsWithSpace = true
                } else {
                    piece.append(character)
                    endsWithSpace = false
                }
            }
        }
        // Within what is left of the budget (OriCmd takes no more).
        piece = piece.prefix(utf8: Self.maxTextBytes - textBytes)
        guard !piece.isEmpty else { return }
        textBytes += piece.utf8.count
        // Changed in place: copying the paragraph for every piece would take long.
        if let last = open?.runs.last, last.0 == style {
            open!.runs[open!.runs.count - 1].1 += piece
        } else {
            open?.runs.append((style, piece))
            runCount += 1
        }
    }

    /// A line break inside the paragraph.
    func lineBreak() {
        guard open != nil else { return }
        text("\u{2028}", style: open?.runs.last?.0 ?? [])
        endsWithSpace = true
    }

    /// Ends the open paragraph (dropped when it holds nothing but spaces).
    func end() {
        guard var block = open else { return }
        open = nil
        // Spaces and line breaks at the end go; so does a paragraph left empty or a bare bullet.
        while !keepsSpaces, let last = block.runs.indices.last {
            let trimmed = String(block.runs[last].1.reversed().drop(while: { $0 == " " || $0 == "\u{2028}" }).reversed())
            if trimmed.isEmpty {
                block.runs.removeLast()
            } else {
                block.runs[last].1 = trimmed
                break
            }
        }
        if block.runs.map(\.1).joined().trimmingCharacters(in: .whitespaces) == "•" { block.runs = [] }
        guard !block.runs.isEmpty, blocks.count < Self.maxBlocks else { return }
        blocks.append(block)
    }

    func separator() {
        end()
        guard blocks.count < Self.maxBlocks, blocks.last?.kind != .separator else { return }
        blocks.append(Block(kind: .separator, level: 0))
    }

    /// Adds a picture made from `data` (JPEG, PNG, GIF, BMP, TIFF, WebP) and returns
    /// its index, or nil when it cannot be read or the pictures fill their share.
    func addImage(_ data: Data) -> Int? {
        guard images.count < Self.maxImages, imageBytes < Self.maxImageBytes, let image = Self.pixels(of: data),
              imageBytes + image.pixels.count <= Self.maxImageBytes else { return nil }
        imageBytes += image.pixels.count
        images.append(image)
        return images.count - 1
    }

    func image(_ index: Int) {
        end()
        guard blocks.count < Self.maxBlocks, images.indices.contains(index) else { return }
        blocks.append(Block(kind: .image, level: 0, image: index))
    }

    private static let pictureTypes: Set<String> = [
        "public.jpeg", "public.png", "com.compuserve.gif", "com.microsoft.bmp", "public.tiff", "org.webmproject.webp",
    ]

    /// The picture scaled to at most `maxImageSide`, as premultiplied RGBA pixels.
    static func pixels(of data: Data) -> (width: Int, height: Int, pixels: Data)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?, pictureTypes.contains(type) else { return nil }
        // A picture claiming huge dimensions would be decoded whole before scaled
        // down (JPEG alone is scaled while decoded): refused.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0, pixelWidth <= 30_000, pixelHeight <= 30_000,
              pixelWidth * pixelHeight <= (type == "public.jpeg" ? 200_000_000 : 50_000_000) else { return nil }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
        let width = min(image.width, maxImageSide), height = min(image.height, maxImageSide)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { return nil }
        return (width, height, Data(bytes: bytes, count: width * height * 4))
    }

    func encoded() -> Data {
        end()
        var data = Data("OBK1".utf8)
        func put(_ value: Int) {
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) }
        }
        func put(_ text: String) {
            put(text.utf8.count)
            data.append(contentsOf: text.utf8)
        }
        put(title.prefix(utf8: 4000))
        put(author.prefix(utf8: 4000))
        put(notice.prefix(utf8: 4000))
        put(blocks.count)
        for block in blocks {
            data.append(block.kind.rawValue)
            data.append(block.level)
            if block.kind == .image {
                put(block.image)
            } else if block.kind != .separator {
                put(block.runs.count)
                for (style, text) in block.runs {
                    data.append(style.rawValue)
                    put(text)
                }
            }
        }
        put(images.count)
        for image in images {
            put(image.width)
            put(image.height)
            data.append(image.pixels)
        }
        // Pages, when a document has them (DjVu).
        if !pages.isEmpty {
            put(pages.count)
            for page in pages {
                put(page.width)
                put(page.height)
                put(page.dpi)
            }
        }
        return data
    }
}

// MARK: - FB2

/// FictionBook 2: the title and author from the description, the cover, the bodies
/// (a second body holds the notes), sections with titles, epigraphs, poems,
/// citations, and pictures from the binaries at the end.
final class FB2Reader: NSObject, XMLParserDelegate {
    private let builder: BookBuilder
    private var path: [String] = []
    /// How many of each element enclose the reader now (the path's contents).
    private var enclosing: [String: Int] = [:]
    private var styles: [BookBuilder.Style] = []
    private var sectionDepth = 0
    private var inNotes = false
    private var titleWords: [String] = []
    private var authorParts: [String: String] = [:]
    private var authorDone = false
    private var fieldText = ""
    /// Pictures in reading order (by binary id) and the binaries, joined at the end.
    private var pictureBlocks: [(position: Int, id: String)] = []
    private var binaries: [String: Data] = [:]
    private var binaryID: String?
    private var binaryText = ""
    private var content: [Content] = []
    private var cover: String?

    /// What was read, replayed into the builder once the pictures are known.
    private enum Content {
        case begin(BookBuilder.Kind, Int)
        case text(String, BookBuilder.Style, BookBuilder.Kind)
        case lineBreak
        case end
        case separator
        case picture(String)
    }

    init(_ builder: BookBuilder) {
        self.builder = builder
    }

    func read(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        builder.title = titleWords.joined(separator: " ")
        builder.author = ["first-name", "middle-name", "last-name"].compactMap { authorParts[$0] }
            .filter { !$0.isEmpty }.joined(separator: " ")
        // The pictures, decoded once each (a failure too), in the order they are shown.
        var decoded: [String: Int?] = [:]
        func picture(_ id: String) -> Int? {
            if let known = decoded[id] { return known }
            let index = binaries[id].flatMap(builder.addImage)
            decoded[id] = index
            return index
        }
        if let cover {
            if let index = picture(cover) { builder.image(index) }
            builder.separator()
        }
        for item in content {
            switch item {
            case .begin(let kind, let level): builder.begin(kind, level: level)
            case .text(let text, let style, let kind): builder.text(text, style: style, kind: kind)
            case .lineBreak: builder.lineBreak()
            case .end: builder.end()
            case .separator: builder.separator()
            case .picture(let id):
                if let index = picture(id) { builder.image(index) }
            }
        }
        builder.end()
    }

    private func inside(_ name: String) -> Bool { enclosing[name, default: 0] > 0 }
    private var inDescription: Bool { inside("description") }

    /// Kept up to a limit (the book past it is left out; a crafted one of empty
    /// paragraphs would otherwise fill the memory).
    private func record(_ item: Content) {
        if content.count < 3 * BookBuilder.maxBlocks { content.append(item) }
    }
    private var paragraphKind: BookBuilder.Kind {
        // Notes' titles are their numbers: not headings (nor in the contents).
        if inside("title") { return inNotes ? .subtitle : .heading }
        if inside("subtitle") { return .subtitle }
        if inside("text-author") { return .signature }
        if inside("v") { return .verse }
        if inside("epigraph") || inside("cite") || inside("annotation") { return .quote }
        if inNotes { return .note }
        return .paragraph
    }

    private static func href(_ attributes: [String: String]) -> String? {
        attributes.first { $0.key == "href" || $0.key.hasSuffix(":href") }?.value
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        path.append(name)
        enclosing[name, default: 0] += 1
        // Deeper than any book (XMLParser would go on): the rest is left out.
        if path.count > 1000 { return parser.abortParsing() }
        if inDescription {
            if name == "image", inside("coverpage"), cover == nil,
               let href = Self.href(attributes), href.hasPrefix("#") {
                cover = String(href.dropFirst())
            }
            fieldText = ""
            return
        }
        switch name {
        case "body":
            inNotes = attributes["name"] == "notes"
            if inNotes { record(.separator) }
        case "section":
            sectionDepth += 1
        case "p", "v", "subtitle", "text-author", "td", "th":
            record(.begin(paragraphKind, min(sectionDepth, 6)))
        case "empty-line":
            record(.separator)
        case "stanza":
            record(.separator)
        case "image":
            if let href = Self.href(attributes), href.hasPrefix("#") {
                record(.picture(String(href.dropFirst())))
            }
        case "emphasis": styles.append(.italic)
        case "strong": styles.append(.bold)
        case "strikethrough": styles.append(.strikethrough)
        case "sub": styles.append(.subscript)
        case "sup": styles.append(.superscript)
        case "code": styles.append(.code)
        case "a" where attributes["type"] == "note": styles.append(.superscript)
        case "a": styles.append([])
        case "binary":
            binaryID = attributes["id"]
            binaryText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer {
            if let last = path.popLast() { enclosing[last, default: 1] -= 1 }
        }
        if inDescription {
            let text = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            if inside("title-info") {
                if name == "book-title" { titleWords.append(text) }
                if inside("author"), !authorDone, ["first-name", "middle-name", "last-name"].contains(name) {
                    authorParts[name] = text
                }
                if name == "author", !authorParts.isEmpty { authorDone = true }
            }
            fieldText = ""
            return
        }
        switch name {
        case "p", "v", "subtitle", "text-author", "td", "th":
            record(.end)
        case "section":
            sectionDepth = max(sectionDepth - 1, 0)
        case "title", "epigraph", "poem", "cite":
            record(.end)
        case "emphasis", "strong", "strikethrough", "sub", "sup", "code", "a":
            if !styles.isEmpty { styles.removeLast() }
        case "binary":
            if let binaryID, binaries.count < BookBuilder.maxImages,
               let data = Data(base64Encoded: binaryText, options: .ignoreUnknownCharacters) {
                binaries[binaryID] = data
            }
            binaryID = nil
            binaryText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inDescription {
            if fieldText.utf8.count < 4096 { fieldText += string }
            return
        }
        if binaryID != nil {
            if binaryText.utf8.count < 48 * 1024 * 1024 { binaryText += string }
            return
        }
        // Text only inside paragraphs (not the spaces between elements).
        guard ["p", "v", "subtitle", "text-author", "td", "th"].contains(where: inside) else { return }
        let style = styles.reduce(into: BookBuilder.Style()) { $0.formUnion($1) }
        record(.text(string, style, paragraphKind))
    }
}

// MARK: - EPUB

/// EPUB: the package (OPF) the container names, its title and author, and the
/// chapters of its spine in order, each an XHTML file read by `HTMLBookReader`.
final class EPUBReader {
    private let builder: BookBuilder

    init(_ builder: BookBuilder) {
        self.builder = builder
    }

    func read(_ zip: inout ZipReader) {
        guard let containerEntry = zip.entry(named: "META-INF/container.xml"),
              let container = zip.contents(of: containerEntry),
              let packagePath = XMLScan(container).first(element: "rootfile")?["full-path"],
              let packageEntry = zip.entry(named: packagePath),
              let package = zip.contents(of: packageEntry) else { return }
        let scan = XMLScan(package)
        builder.title = scan.text(of: "title") ?? ""
        builder.author = scan.text(of: "creator") ?? ""
        let base = (packagePath as NSString).deletingLastPathComponent
        var manifest: [String: (href: String, type: String)] = [:]
        for item in scan.elements(named: "item") {
            if let id = item["id"], let href = item["href"] {
                manifest[id] = (href, item["media-type"] ?? "")
            }
        }
        var pictures: [String: Int?] = [:]
        for reference in scan.elements(named: "itemref") {
            guard let id = reference["idref"], let item = manifest[id],
                  item.type.contains("html") || item.href.lowercased().hasSuffix("htm") || item.href.lowercased().hasSuffix("html")
            else { continue }
            let path = Self.join(base, item.href)
            guard let entry = zip.entry(named: path), let chapter = zip.contents(of: entry) else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            HTMLBookReader(builder).read(Self.text(of: chapter)) { source in
                let picturePath = Self.join(directory, source)
                if let known = pictures[picturePath] { return known }
                let index = zip.entry(named: picturePath).flatMap { zip.contents(of: $0) }.flatMap(self.builder.addImage)
                pictures[picturePath] = index
                return index
            }
            builder.separator()
        }
    }

    /// A path inside the zip: `href` (percent-encoded, maybe with ../) from `directory`.
    /// A path inside the zip: `href` (percent-encoded, maybe with ../, a query or a
    /// fragment; from the zip's root when it starts with /) from `directory`.
    static func join(_ directory: String, _ href: String) -> String {
        let bare = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .flatMap { $0.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first }
            .map(String.init) ?? href
        let clean = bare.removingPercentEncoding ?? bare
        var parts = directory.isEmpty || clean.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for part in clean.split(separator: "/").map(String.init) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// A chapter's text: UTF-8 (as EPUB requires), else UTF-16 by its mark, else Windows-1251.
    static func text(of data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        // The encoding the chapter names (<?xml encoding=…?> or <meta charset=…>).
        let start = String(decoding: data.prefix(1024), as: UTF8.self)
        if let range = start.range(of: #"(encoding|charset)\s*=\s*["']?([A-Za-z0-9_.:-]+)"#, options: .regularExpression) {
            let name = start[range].split(whereSeparator: { "=\"' ".contains($0) }).last.map(String.init) ?? ""
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Elements and texts of a small XML file (an EPUB container or package), names
/// without prefixes.
struct XMLScan {
    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [(name: String, attributes: [String: String], text: String)] = []
        private var open: [Int] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            guard elements.count < 100_000 else { return parser.abortParsing() }
            var plain: [String: String] = [:]
            for (key, value) in attributes {
                plain[String(key.split(separator: ":").last ?? Substring(key))] = value
            }
            elements.append((name, plain, ""))
            open.append(elements.count - 1)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if !open.isEmpty { open.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let last = open.last, elements[last].text.utf8.count < 4096 { elements[last].text += string }
        }
    }

    private let collector = Collector()

    init(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
    }

    func elements(named name: String) -> [[String: String]] {
        collector.elements.filter { $0.name == name }.map(\.attributes)
    }

    func first(element name: String) -> [String: String]? {
        collector.elements.first { $0.name == name }?.attributes
    }

    func text(of name: String) -> String? {
        collector.elements.first { $0.name == name }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HTML chapters

/// A chapter of (X)HTML as book blocks: headings, paragraphs, quotes, lists,
/// preformatted text, line breaks, rules and pictures; bold, italic, code,
/// superscript and subscript; scripts, styles and the head dropped. Tolerant of
/// what browsers forgive.
final class HTMLBookReader {
    private let builder: BookBuilder
    private var styles: [(tag: String, style: BookBuilder.Style)] = []
    private var quoteDepth = 0
    private var preDepth = 0

    init(_ builder: BookBuilder) {
        self.builder = builder
    }

    /// `picture` gives the index of the picture at a source path (nil: none).
    func read(_ text: String, picture: (String) -> Int?) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var textStart = 0
        func flush(upTo end: Int) {
            guard end > textStart else { return }
            var piece = String.UnicodeScalarView()
            piece.append(contentsOf: scalars[textStart..<end])
            let text = HTMLTableReader.decodeEntities(String(piece))
            guard preDepth > 0 || text.contains(where: { !$0.isWhitespace }) || isInParagraph else { return }
            let style = styles.reduce(into: BookBuilder.Style()) { $0.formUnion($1.style) }
            builder.text(text, style: style, kind: currentKind)
            isInParagraph = true
        }
        while index < scalars.count {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }
            flush(upTo: index)
            if Self.matches(scalars, at: index, "<!--") {
                index = Self.find(scalars, "-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                textStart = index
                continue
            }
            guard let end = Self.tagEnd(scalars, from: index + 1) else {
                // A < that opens no tag: text.
                textStart = index
                break
            }
            var tag = String.UnicodeScalarView()
            tag.append(contentsOf: scalars[(index + 1)..<end])
            index = end + 1
            textStart = index
            let (name, closing, attributes) = Self.parseTag(String(tag))
            // What these hold is no text (unless they close themselves: <script/>).
            if !closing, !String(tag).hasSuffix("/"), ["script", "style", "head", "title"].contains(name) {
                index = Self.find(scalars, "</" + name, from: index) ?? scalars.count
                textStart = index
                continue
            }
            handle(name, closing: closing, attributes: attributes, picture: picture)
        }
        flush(upTo: scalars.count)
        builder.end()
    }

    private var isInParagraph = false

    private var currentKind: BookBuilder.Kind {
        preDepth > 0 ? .preformatted : quoteDepth > 0 ? .quote : .paragraph
    }

    private func endParagraph() {
        builder.end()
        isInParagraph = false
    }

    private static let inline: [String: BookBuilder.Style] = [
        "b": .bold, "strong": .bold, "i": .italic, "em": .italic, "cite": .italic, "var": .italic, "dfn": .italic,
        "code": .code, "tt": .code, "kbd": .code, "samp": .code, "sup": .superscript, "sub": .subscript,
        "s": .strikethrough, "strike": .strikethrough, "del": .strikethrough,
    ]

    private func handle(_ name: String, closing: Bool, attributes: [String: String], picture: (String) -> Int?) {
        if let style = Self.inline[name] {
            if closing {
                if let last = styles.lastIndex(where: { $0.tag == name }) { styles.remove(at: last) }
            } else if styles.count < 64 {
                styles.append((name, style))
            }
            return
        }
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            endParagraph()
            if !closing {
                builder.begin(.heading, level: Int(String(name.dropFirst())) ?? 1)
                isInParagraph = true
            }
        case "p", "div", "section", "article", "dd", "dt", "tr", "table", "figure", "figcaption", "aside", "header",
             "footer", "nav", "body":
            endParagraph()
        case "li":
            endParagraph()
            if !closing {
                builder.begin(currentKind)
                builder.text("• ", kind: currentKind)
                isInParagraph = true
            }
        case "td", "th":
            if !closing, isInParagraph { builder.text(" · ", kind: currentKind) }
        case "blockquote":
            endParagraph()
            quoteDepth = max(quoteDepth + (closing ? -1 : 1), 0)
        case "pre":
            endParagraph()
            preDepth = max(preDepth + (closing ? -1 : 1), 0)
            if !closing { builder.begin(.preformatted) }
        case "br":
            if isInParagraph { builder.lineBreak() }
        case "hr", "pagebreak":
            builder.separator()
            isInParagraph = false
        case "img", "image":
            guard !closing else { return }
            // Mobipocket numbers its pictures (recindex).
            let source = attributes["src"] ?? attributes["href"] ?? attributes["xlink:href"]
                ?? attributes["recindex"].map { "recindex:" + $0 }
            if let source, let index = picture(source) {
                builder.image(index)
                isInParagraph = false
            }
        default:
            break
        }
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ text: String) -> Bool {
        let pattern = Array(text.unicodeScalars)
        guard index + pattern.count <= scalars.count else { return false }
        return scalars[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    /// The first `text` from `start`, letter case ignored.
    private static func find(_ scalars: [Unicode.Scalar], _ text: String, from start: Int) -> Int? {
        let pattern = Array(text.lowercased().unicodeScalars)
        guard !pattern.isEmpty, start <= scalars.count - pattern.count else { return nil }
        var index = start
        while index <= scalars.count - pattern.count {
            var matched = true
            for (offset, expected) in pattern.enumerated() {
                var scalar = scalars[index + offset]
                if ("A"..."Z").contains(scalar) { scalar = Unicode.Scalar(scalar.value + 32) ?? scalar }
                if scalar != expected {
                    matched = false
                    break
                }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }

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

    /// The name (lowercased, without a namespace prefix), whether it closes, and the
    /// attributes of pictures (names lowercased).
    private static func parseTag(_ tag: String) -> (String, Bool, [String: String]) {
        var body = Substring(tag)
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let qualified = body.prefix { $0.isLetter || $0.isNumber || $0 == ":" }.lowercased()
        let name = String(qualified.split(separator: ":").last ?? Substring(qualified))
        var attributes: [String: String] = [:]
        if !closing, name == "img" || name == "image" {
            let text = String(body.dropFirst(qualified.count))
            let pattern = #"([A-Za-z:-]+)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+)"#
            let expression = try? NSRegularExpression(pattern: pattern)
            expression?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
                guard let match, let key = Range(match.range(at: 1), in: text),
                      let value = Range(match.range(at: 2), in: text) else { return }
                attributes[text[key].lowercased()] = HTMLTableReader.decodeEntities(
                    text[value].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return (name, closing, attributes)
    }
}
