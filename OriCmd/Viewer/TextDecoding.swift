import Foundation

nonisolated enum TextDecoding {
    /// Decodes UTF-8, falling back to encoding detection (Windows-1251, KOI8-R, …).
    static func string(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        var converted: NSString?
        let koi8 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        _ = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [String.Encoding.windowsCP1251.rawValue, koi8.rawValue],
            .allowLossyKey: true,
        ], convertedString: &converted, usedLossyConversion: nil)
        return (converted as String?) ?? String(decoding: data, as: UTF8.self)
    }

    /// Text files have no NUL bytes near the start.
    static func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(8192).contains(0)
    }
}
