import Foundation

/// Total Commander's Encode File / Decode File: a file as text for mail — MIME
/// (base64, with headers naming the file), UUE or XXE (`begin 644 name` … `end`) —
/// and such a text back to the file it holds.
nonisolated enum MailEncoding: Int, CaseIterable, Sendable {
    case mime, uue, xxe

    var title: String {
        switch self {
        case .mime: "MIME (Base64)"
        case .uue: "UUE"
        case .xxe: "XXE"
        }
    }

    var fileExtension: String {
        switch self {
        case .mime: "b64"
        case .uue: "uue"
        case .xxe: "xxe"
        }
    }

    /// The characters standing for 0…63 in UUE (0 written as `) and XXE.
    private var alphabet: [UInt8] {
        switch self {
        case .mime: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        case .uue: [UInt8(ascii: "`")] + (33...95).map { UInt8($0) }
        case .xxe: Array("+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        }
    }

    /// The text holding `data` named `name`.
    func encode(_ data: Data, name: String) -> String {
        if self == .mime {
            let body = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                          .endLineWithLineFeed])
            return "MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"\(name)\"\r\n"
                + "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\n\r\n"
                + body + "\r\n"
        }
        let table = alphabet
        var lines = ["begin 644 \(name)"]
        let bytes = [UInt8](data)
        for start in stride(from: 0, to: bytes.count, by: 45) {
            let chunk = Array(bytes[start..<min(start + 45, bytes.count)])
            var line = [table[chunk.count]]
            for group in stride(from: 0, to: chunk.count, by: 3) {
                let a = chunk[group], b = group + 1 < chunk.count ? chunk[group + 1] : 0
                let c = group + 2 < chunk.count ? chunk[group + 2] : 0
                line += [table[Int(a >> 2)], table[Int((a & 3) << 4 | b >> 4)], table[Int((b & 15) << 2 | c >> 6)],
                         table[Int(c & 63)]]
            }
            lines.append(String(decoding: line, as: UTF8.self))
        }
        lines += [String(decoding: [table[0]], as: UTF8.self), "end", ""]
        return lines.joined(separator: "\n")
    }

    /// The file a mail text holds: its name (from the headers or the begin line;
    /// nil when none is given) and data; nil when it holds none.
    static func decode(_ text: String) -> (name: String?, data: Data)? {
        // \r\n would make an empty line between the two characters.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        if let begin = lines.firstIndex(where: { $0.hasPrefix("begin ") }) {
            let name = lines[begin].split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init)
            let body = lines[(begin + 1)...].prefix { $0.trimmingCharacters(in: .whitespaces) != "end" }
            // UUE has no lowercase letters; XXE has them ("h" stands for a line of 45 bytes).
            let xxe = body.contains { $0.contains(where: \.isLowercase) }
            guard let data = (xxe ? MailEncoding.xxe : .uue).decodeLines(Array(body))
                    ?? (xxe ? MailEncoding.uue : .xxe).decodeLines(Array(body)) else { return nil }
            return (name, data)
        }
        // MIME: the headers, a blank line, base64.
        var name: String?
        var bodyStart = 0
        if lines.first?.contains(":") == true, let blank = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            for line in lines[..<blank] {
                for key in ["filename=", "name="] {
                    if let range = line.range(of: key) {
                        name = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
                    }
                }
            }
            bodyStart = blank + 1
        }
        let body = lines[bodyStart...].prefix { !$0.hasPrefix("--") }.joined()
        guard !body.isEmpty, let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        return (name, data)
    }

    /// UUE / XXE lines: each starts with its byte count.
    private func decodeLines(_ lines: [String]) -> Data? {
        var values = [UInt8](repeating: 255, count: 256)
        for (value, character) in alphabet.enumerated() { values[Int(character)] = UInt8(value) }
        if self == .uue { values[Int(UInt8(ascii: " "))] = 0 }
        var data = Data()
        for line in lines {
            let bytes = Array(line.utf8)
            guard let first = bytes.first else { continue }
            let count = Int(values[Int(first)])
            guard count != 255 else { return nil }
            if count == 0 { break }
            var decoded: [UInt8] = []
            var index = 1
            while decoded.count < count, index + 3 < bytes.count + 1 {
                let quad = (0..<4).map { index + $0 < bytes.count ? values[Int(bytes[index + $0])] : 0 }
                guard !quad.contains(255) else { return nil }
                decoded += [quad[0] << 2 | quad[1] >> 4, (quad[1] & 15) << 4 | quad[2] >> 2, (quad[2] & 3) << 6 | quad[3]]
                index += 4
            }
            guard decoded.count >= count else { return nil }
            data.append(contentsOf: decoded.prefix(count))
        }
        return data
    }
}
