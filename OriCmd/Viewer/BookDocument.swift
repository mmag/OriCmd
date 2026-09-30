import AppKit

/// A book for the Lister's book view (FB2, EPUB, …), as the helper service reads
/// it. The data is checked as coming from a stranger — a service taken over could
/// send anything: every count, text and picture size is bounded, anything amiss
/// drops the whole reply, and pictures arrive as plain pixels (no decoder runs on
/// them here).
nonisolated struct BookDocument: Sendable {
    enum Kind: UInt8, Sendable {
        case paragraph = 0, heading, quote, verse, image, separator, note, preformatted, subtitle, signature
    }

    struct Run: Sendable {
        var bold, italic, code, superscript, `subscript`, strikethrough: Bool
        var text: String
    }

    struct Block: Sendable {
        var kind: Kind
        var level: Int
        var runs: [Run]
        var image: Int
    }

    struct Picture: Sendable {
        var width: Int
        var height: Int
        var pixels: Data
    }

    var title: String
    var author: String
    var notice: String
    var blocks: [Block]
    var pictures: [Picture]
    /// A DjVu document's pages: pixels and resolution.
    var pages: [(width: Int, height: Int, dpi: Int)] = []

    private static let maxBlocks = 1_000_000
    private static let maxRuns = 4_000_000
    private static let maxText = 96 * 1024 * 1024
    private static let maxPictures = 1000
    private static let maxPictureBytes = 160 * 1024 * 1024
    private static let maxSide = 1400
    private static let maxBytes = 300 * 1024 * 1024

    init?(_ data: Data) {
        guard data.count <= Self.maxBytes, data.starts(with: Array("OBK1".utf8)) else { return nil }
        var reader = Reader(data: data, offset: 4)
        guard let title = reader.text(maxBytes: 4000), let author = reader.text(maxBytes: 4000),
              let notice = reader.text(maxBytes: 4000), let blockCount = reader.count(max: Self.maxBlocks)
        else { return nil }
        var blocks: [Block] = []
        blocks.reserveCapacity(blockCount)
        var runsLeft = Self.maxRuns, textLeft = Self.maxText
        var pictureReferences: [Int] = []
        for _ in 0..<blockCount {
            guard let kindByte = reader.byte(), let kind = Kind(rawValue: kindByte), let level = reader.byte(), level <= 6
            else { return nil }
            var block = Block(kind: kind, level: Int(level), runs: [], image: 0)
            switch kind {
            case .image:
                guard let index = reader.count(max: Self.maxPictures - 1) else { return nil }
                block.image = index
                pictureReferences.append(index)
            case .separator:
                break
            default:
                guard let runCount = reader.count(max: runsLeft) else { return nil }
                runsLeft -= runCount
                for _ in 0..<runCount {
                    guard let style = reader.byte(), style < 64, let text = reader.text(maxBytes: textLeft) else { return nil }
                    textLeft -= text.utf8.count
                    block.runs.append(Run(bold: style & 1 != 0, italic: style & 2 != 0, code: style & 4 != 0,
                                          superscript: style & 8 != 0, subscript: style & 16 != 0,
                                          strikethrough: style & 32 != 0, text: text))
                }
            }
            blocks.append(block)
        }
        guard let pictureCount = reader.count(max: Self.maxPictures) else { return nil }
        var pictures: [Picture] = []
        var pictureBytes = 0
        for _ in 0..<pictureCount {
            guard let width = reader.count(max: Self.maxSide), let height = reader.count(max: Self.maxSide),
                  width > 0, height > 0, pictureBytes + width * height * 4 <= Self.maxPictureBytes,
                  let pixels = reader.bytes(width * height * 4) else { return nil }
            pictureBytes += pixels.count
            pictures.append(Picture(width: width, height: height, pixels: pixels))
        }
        var pages: [(width: Int, height: Int, dpi: Int)] = []
        if reader.offset < data.count {
            guard let count = reader.count(max: 100_000) else { return nil }
            for _ in 0..<count {
                guard let width = reader.count(max: 65_535), let height = reader.count(max: 65_535),
                      let dpi = reader.count(max: 6000) else { return nil }
                pages.append((width, height, dpi))
            }
        }
        guard reader.offset == data.count, pictureReferences.allSatisfy({ $0 < pictures.count }) else { return nil }
        self.pages = pages
        self.title = title
        self.author = author
        self.notice = notice
        self.blocks = blocks
        self.pictures = pictures
    }

    private struct Reader {
        let data: Data
        var offset: Int

        mutating func byte() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func count(max: Int) -> Int? {
            guard max >= 0, offset + 4 <= data.count else { return nil }
            let value = data.withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            offset += 4
            return value <= max ? value : nil
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data[data.startIndex + offset ..< data.startIndex + offset + count]
        }

        mutating func text(maxBytes: Int) -> String? {
            guard let length = count(max: maxBytes), let bytes = bytes(length) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }

    // MARK: - Showing

    /// The book as text to read, and its contents: the headings of the first two
    /// levels with where they start.
    func typeset() -> (text: NSAttributedString, contents: [(title: String, location: Int, level: Int)]) {
        let text = NSMutableAttributedString()
        var contents: [(String, Int, Int)] = []
        let body = Self.serif(size: 16)
        func paragraph(_ configure: (NSMutableParagraphStyle) -> Void) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.15
            style.paragraphSpacing = 4
            configure(style)
            return style
        }
        let styles: [Kind: NSParagraphStyle] = [
            .paragraph: paragraph { $0.firstLineHeadIndent = 24 },
            .heading: paragraph { $0.alignment = .center; $0.paragraphSpacingBefore = 22; $0.paragraphSpacing = 12 },
            .subtitle: paragraph { $0.alignment = .center; $0.paragraphSpacingBefore = 8; $0.paragraphSpacing = 8 },
            .quote: paragraph { $0.headIndent = 120; $0.firstLineHeadIndent = 120 },
            .signature: paragraph { $0.alignment = .right; $0.paragraphSpacing = 12 },
            .verse: paragraph { $0.headIndent = 72; $0.firstLineHeadIndent = 48; $0.paragraphSpacing = 0 },
            .note: paragraph { $0.firstLineHeadIndent = 16 },
            .preformatted: paragraph { $0.lineHeightMultiple = 1 },
            .image: paragraph { $0.alignment = .center; $0.paragraphSpacingBefore = 8; $0.paragraphSpacing = 8 },
            .separator: paragraph { $0.alignment = .center },
        ]
        if !notice.isEmpty {
            // Notices come as codes, said here in the interface's language.
            let said = switch notice {
            case "drm": String(localized: "This book is protected (DRM): it can only be read in the program it was bought for.")
            case "djvu-no-text": String(localized: "This DjVu document has no text layer.")
            case "djvu-indirect": String(localized: "This DjVu document keeps its pages in other files; open the one that lists them all.")
            default: notice
            }
            text.append(NSAttributedString(string: said + "\n", attributes: [
                .font: Self.serif(size: 16, bold: true), .foregroundColor: NSColor.systemRed,
                .paragraphStyle: styles[.heading] as Any,
            ]))
        }
        for block in blocks {
            let paragraphStyle = styles[block.kind] ?? styles[.paragraph]!
            switch block.kind {
            case .separator:
                text.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: paragraphStyle]))
            case .image:
                let attachment = NSTextAttachment()
                if let image = Self.image(pictures[block.image]) {
                    attachment.image = image
                    // At most a column wide and a screen high, never enlarged much.
                    let scale = min(1, 560 / image.size.width, 700 / image.size.height)
                    attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale,
                                               height: image.size.height * scale)
                }
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.append(NSAttributedString(string: "\n"))
                piece.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: piece.length))
                text.append(piece)
            default:
                let start = text.length
                let size: CGFloat = switch (block.kind, block.level) {
                case (.heading, 0), (.heading, 1): 24
                case (.heading, 2): 20
                case (.heading, 3): 18
                case (.note, _), (.preformatted, _): 13
                case (.quote, _), (.signature, _): 15
                default: 16
                }
                let boldKind = block.kind == .heading || block.kind == .subtitle
                let italicKind = block.kind == .quote || block.kind == .signature
                for run in block.runs {
                    var font = run.code || block.kind == .preformatted
                        ? NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular)
                        : Self.serif(size: size, bold: boldKind || run.bold, italic: italicKind != run.italic)
                    var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
                    if run.superscript || run.subscript {
                        font = NSFontManager.shared.convert(font, toSize: size * 0.7)
                        attributes[.baselineOffset] = run.superscript ? size * 0.35 : -size * 0.15
                    }
                    if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    attributes[.font] = font
                    text.append(NSAttributedString(string: run.text, attributes: attributes))
                }
                text.append(NSAttributedString(string: "\n", attributes: [.font: body]))
                text.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: start, length: text.length - start))
                if block.kind == .heading, block.level <= 2, contents.count < 2000 {
                    let title = block.runs.map(\.text).joined().replacingOccurrences(of: "\u{2028}", with: " ")
                    contents.append((String(title.prefix(120)), start, max(block.level, 1)))
                }
            }
        }
        return (text, contents)
    }

    private static func serif(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if let descriptor = font.fontDescriptor.withDesign(.serif), let serif = NSFont(descriptor: descriptor, size: size) {
            font = serif
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// A picture from its pixels (premultiplied RGBA, sRGB); no decoder involved.
    private static func image(_ picture: Picture) -> NSImage? {
        guard let provider = CGDataProvider(data: picture.pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: picture.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // Pixels at twice the points, as on a Retina screen.
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(picture.width) / 2, height: CGFloat(picture.height) / 2))
    }
}

/// A typeset book handed from the task that made it to the window.
nonisolated final class Typeset: @unchecked Sendable {
    let text: NSAttributedString
    let contents: [(title: String, location: Int, level: Int)]

    init(_ typeset: (text: NSAttributedString, contents: [(title: String, location: Int, level: Int)])) {
        text = typeset.text
        contents = typeset.contents
    }
}

extension Optional {
    /// The value mapped by an async function.
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
