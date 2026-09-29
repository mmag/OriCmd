import Foundation

/// Text encodings the Lister offers (menu and keys), besides telling them itself.
nonisolated enum TextEncoding: CaseIterable, Sendable {
    case automatic, utf8, utf16, windows1251, dos866, koi8r, macCyrillic, iso88595, windows1252, latin1

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatically")
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .windows1251: "Windows-1251"
        case .dos866: String(localized: "DOS (866)")
        case .koi8r: "KOI8-R"
        case .macCyrillic: "Mac Cyrillic"
        case .iso88595: "ISO-8859-5"
        case .windows1252: "Windows-1252"
        case .latin1: "ISO-8859-1 (Latin-1)"
        }
    }

    /// The Lister key: A (ANSI) and S (ASCII) as Total Commander's Windows and DOS
    /// character sets, here the Cyrillic ones.
    var key: String? {
        switch self {
        case .utf8: "8"
        case .utf16: "u"
        case .windows1251: "a"
        case .dos866: "s"
        case .koi8r: "k"
        default: nil
        }
    }

    /// The single-byte and UTF-8 encodings (UTF-16 has two byte orders).
    fileprivate var stringEncoding: String.Encoding? {
        func cf(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        return switch self {
        case .automatic, .utf16: nil
        case .utf8: .utf8
        case .windows1251: .windowsCP1251
        case .dos866: cf(.dosRussian)
        case .koi8r: cf(.KOI8_R)
        case .macCyrillic: cf(.macCyrillic)
        case .iso88595: cf(.isoLatinCyrillic)
        case .windows1252: .windowsCP1252
        case .latin1: .isoLatin1
        }
    }
}

nonisolated enum TextDecoding {
    /// Decodes UTF-8, falling back to encoding detection (Windows-1251, KOI8-R, …).
    static func string(from data: Data) -> String {
        decode(data, as: .automatic).text
    }

    /// Decodes `data` as `encoding` (bytes it cannot read become replacement
    /// characters), or tells the encoding: UTF-16 by its byte order mark or zero
    /// bytes, UTF-8, then the most likely one (Windows-1251, KOI8-R, …). Returns the
    /// name of the encoding used. `truncated`: the data ends inside the file, maybe
    /// amid a character.
    static func decode(_ data: Data, as encoding: TextEncoding, truncated: Bool = false) -> (text: String, name: String) {
        switch encoding {
        case .automatic:
            let utf16 = utf16ByteOrder(of: data) != nil
            if !utf16, let text = utf8(data, truncated: truncated) {
                return (text, TextEncoding.utf8.title)
            }
            if utf16 {
                return (decodeUTF16(data), TextEncoding.utf16.title)
            }
            var converted: NSString?
            let raw = NSString.stringEncoding(for: data, encodingOptions: [
                .suggestedEncodingsKey: [TextEncoding.windows1251, .koi8r].compactMap { $0.stringEncoding?.rawValue },
                .allowLossyKey: true,
            ], convertedString: &converted, usedLossyConversion: nil)
            guard let converted, raw != 0 else { return (String(decoding: data, as: UTF8.self), TextEncoding.utf8.title) }
            let known = TextEncoding.allCases.first { $0.stringEncoding?.rawValue == raw }
            return (converted as String, known?.title ?? String.localizedName(of: String.Encoding(rawValue: raw)))
        case .utf8:
            return (utf8(data, truncated: truncated) ?? String(decoding: data, as: UTF8.self), encoding.title)
        case .utf16:
            return (decodeUTF16(data), encoding.title)
        default:
            guard let stringEncoding = encoding.stringEncoding else { return (string(from: data), encoding.title) }
            if let text = String(data: data, encoding: stringEncoding) {
                return (text, encoding.title)
            }
            // Bytes a code page leaves undefined (0x98 in Windows-1251).
            var converted: NSString?
            _ = NSString.stringEncoding(for: data, encodingOptions: [
                .suggestedEncodingsKey: [stringEncoding.rawValue], .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: true,
            ], convertedString: &converted, usedLossyConversion: nil)
            return ((converted as String?) ?? String(decoding: data, as: UTF8.self), encoding.title)
        }
    }

    /// Text files have no NUL bytes near the start, unless they are UTF-16.
    static func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(8192).contains(0) || utf16ByteOrder(of: data) != nil
    }

    /// Valid UTF-8 without its byte order mark; a character cut by the end of
    /// `truncated` data does not count.
    private static func utf8(_ data: Data, truncated: Bool) -> String? {
        let text = String(data: data, encoding: .utf8)
            ?? (truncated ? (1...3).lazy.compactMap { String(data: data.dropLast($0), encoding: .utf8) }.first : nil)
        return text.map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
    }

    /// Little-endian unless the data says otherwise (Windows writes it so).
    private static func decodeUTF16(_ data: Data) -> String {
        let bigEndian = utf16ByteOrder(of: data) == .bigEndian
        var body = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? data.dropFirst(2) : data[...]
        if body.count % 2 == 1 { body = body.dropLast() }
        let units = stride(from: body.startIndex, to: body.endIndex, by: 2).map { index in
            let first = UInt16(body[index]), second = UInt16(body[index + 1])
            return bigEndian ? first << 8 | second : second << 8 | first
        }
        return String(decoding: units, as: UTF16.self)
    }

    private enum ByteOrder { case littleEndian, bigEndian }

    /// UTF-16 by its byte order mark, or by its high bytes: a few values only (0 for
    /// Latin letters, digits and spaces, 4 for Cyrillic), zero now and then, while the
    /// low bytes never are.
    private static func utf16ByteOrder(of data: Data) -> ByteOrder? {
        if data.starts(with: [0xFF, 0xFE]) { return .littleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .bigEndian }
        let head = [UInt8](data.prefix(8192))
        let pairs = head.count / 2
        guard pairs >= 2 else { return nil }
        func highByte(at high: Int) -> Bool {
            var lowZeros = 0
            var highs: [UInt8: Int] = [:]
            for pair in 0..<pairs {
                if head[pair * 2 + 1 - high] == 0 { lowZeros += 1 }
                highs[head[pair * 2 + high], default: 0] += 1
            }
            let common = highs.values.sorted(by: >).prefix(2).reduce(0, +)
            return lowZeros * 50 <= pairs && common * 10 >= pairs * 9 && highs[0, default: 0] * 20 >= pairs
        }
        if highByte(at: 1) { return .littleEndian }
        if highByte(at: 0) { return .bigEndian }
        return nil
    }
}
