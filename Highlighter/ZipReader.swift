import Compression
import Foundation

/// Reads the files of a zip (EPUB books, .fb2.zip) from memory, within limits
/// that keep a crafted zip from filling the memory: a few thousand entries, each
/// at most 64 MB unpacked and 256 MB in all, compressed at most a thousand to one.
/// Stored and deflated entries only.
struct ZipReader {
    struct Entry {
        let name: String
        fileprivate let method: UInt16
        fileprivate let compressedSize: Int
        fileprivate let size: Int
        fileprivate let localHeader: Int
    }

    static let maxEntries = 10_000
    static let maxEntrySize = 64 * 1024 * 1024
    static let maxTotalSize = 256 * 1024 * 1024

    private let data: Data
    private(set) var entries: [Entry] = []
    private var unpacked = 0

    init?(_ data: Data) {
        self.data = data
        // The end of central directory record, searched from the end (a comment may follow it).
        let minimum = 22
        guard data.count >= minimum else { return nil }
        var end = -1
        var position = data.count - minimum
        let lowest = max(0, data.count - minimum - 65_535)
        while position >= lowest {
            if uint32(at: position) == 0x0605_4B50 {
                end = position
                break
            }
            position -= 1
        }
        guard end >= 0, let count = uint16(at: end + 10), let directoryOffset = uint32(at: end + 16)
        else { return nil }
        guard Int(count) <= Self.maxEntries else { return nil }
        var offset = Int(directoryOffset)
        for _ in 0..<Int(count) {
            guard uint32(at: offset) == 0x0201_4B50, let method = uint16(at: offset + 10),
                  let compressed = uint32(at: offset + 20), let size = uint32(at: offset + 24),
                  let nameLength = uint16(at: offset + 28), let extraLength = uint16(at: offset + 30),
                  let commentLength = uint16(at: offset + 32), let local = uint32(at: offset + 42),
                  offset + 46 + Int(nameLength) <= data.count else { return nil }
            let nameBytes = data[data.startIndex + offset + 46 ..< data.startIndex + offset + 46 + Int(nameLength)]
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: Int(compressed), size: Int(size),
                                 localHeader: Int(local)))
            offset += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
    }

    /// The entry named `name` (letter case ignored, as some books get it wrong).
    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }

    /// The unpacked contents of `entry`; nil when damaged, unsupported or past the limits.
    mutating func contents(of entry: Entry) -> Data? {
        guard entry.size <= Self.maxEntrySize, unpacked + entry.size <= Self.maxTotalSize,
              entry.compressedSize <= data.count, entry.size <= max(entry.compressedSize, 1) * 1000 + 4096,
              uint32(at: entry.localHeader) == 0x0403_4B50,
              let nameLength = uint16(at: entry.localHeader + 26), let extraLength = uint16(at: entry.localHeader + 28)
        else { return nil }
        let start = entry.localHeader + 30 + Int(nameLength) + Int(extraLength)
        guard start >= 0, start + entry.compressedSize <= data.count else { return nil }
        let packed = data[data.startIndex + start ..< data.startIndex + start + entry.compressedSize]
        let result: Data?
        switch entry.method {
        case 0:
            result = entry.size == entry.compressedSize ? Data(packed) : nil
        case 8:
            result = Self.inflate(packed, size: entry.size)
        default:
            result = nil
        }
        if let result { unpacked += result.count }
        return result
    }

    /// Raw deflate (what zip stores) into exactly `size` bytes.
    private static func inflate(_ packed: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard !packed.isEmpty else { return nil }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { target in
            packed.withUnsafeBytes { source in
                compression_decode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? output : nil
    }

    private func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    private func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}
