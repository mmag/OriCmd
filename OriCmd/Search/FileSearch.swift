import Foundation
import os

/// Recursive file search by mask and, optionally, by contained text, the date,
/// the size and attributes. Runs on a background thread; the UI polls `snapshot`
/// for results.
nonisolated final class FileSearch: Sendable {
    struct Query: Sendable {
        let root: URL
        let masks: String
        let text: String
        let caseSensitive: Bool
        /// How many levels of subfolders to go into: nil — all, 0 — none.
        var depth: Int?
        /// Modified at or after / before (the modification date of the item itself,
        /// not of a symbolic link's target).
        var modifiedAfter: Date?
        var modifiedBefore: Date?
        /// Only files (not folders) of such a size.
        var size: SizeCondition?
        /// Attributes an item must have (true) or must not have (false); the others
        /// do not matter.
        var attributes: [Attribute: Bool] = [:]
        /// `masks` is a regular expression for the name (case-insensitive).
        var nameIsRegex = false
        /// `text` is a regular expression.
        var textIsRegex = false
        var wholeWords = false
        /// Files without the text instead of with it.
        var notContaining = false
        /// The encodings the text is looked for in, any of them.
        var encodings: [TextEncoding] = [.utf8]
        /// `text` is bytes in hex ("50 4B 03 04"), looked for as they are.
        var isHex = false
    }

    enum QueryError: Error {
        case nameRegex, textRegex, hex
    }

    enum Attribute: Sendable, Hashable, CaseIterable {
        case folder, hidden, locked, symbolicLink, executable
    }

    struct SizeCondition: Sendable {
        enum Comparison: Sendable {
            case equal, less, greater
        }

        let comparison: Comparison
        let value: Int64
        /// Bytes in a unit of `value` (1, 1024, …).
        let unit: Int64

        /// "= 2 MB" takes the sizes from 2 MB up to (not including) 3 MB, as a
        /// size shown in whole megabytes would read.
        func matches(_ size: Int64) -> Bool {
            switch comparison {
            case .equal: size / unit == value
            case .less: size < value * unit
            case .greater: size > value * unit
            }
        }
    }

    struct State {
        var found: [URL] = []
        var scannedCount = 0
        var isCancelled = false
        var isFinished = false
    }

    /// Larger files are not searched for text.
    private static let textSearchLimit = 256 * 1024 * 1024

    let query: Query
    private let nameRegex: NSRegularExpression?
    private let text: TextMatcher?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(query: Query) throws(QueryError) {
        self.query = query
        if query.nameIsRegex {
            guard let regex = try? NSRegularExpression(pattern: query.masks, options: .caseInsensitive) else {
                throw .nameRegex
            }
            nameRegex = regex
        } else {
            nameRegex = nil
        }
        text = query.text.isEmpty ? nil : try TextMatcher(query)
    }

    var snapshot: State { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    @concurrent
    func run() async {
        walk(query.root, level: 0)
        state.withLock { $0.isFinished = true }
    }

    private var isCancelled: Bool { state.withLock { $0.isCancelled } }

    /// `level`: how many subfolders below the root `directory` is.
    private func walk(_ directory: URL, level: Int) {
        guard !isCancelled, let names = try? DirectoryListing.names(in: directory) else { return }
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if isCancelled { return }
            let url = directory.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let isFolder = info.st_mode & S_IFMT == S_IFDIR

            // Text is only looked for in regular files (also behind a symbolic link):
            // a FIFO or a device would block or never end.
            var target = stat()
            let isLink = info.st_mode & S_IFMT == S_IFLNK
            let isRegular = info.st_mode & S_IFMT == S_IFREG
                || (isLink && stat(url.path, &target) == 0 && target.st_mode & S_IFMT == S_IFREG)
            let file = isRegular ? (isLink ? target : info) : nil
            if matchesName(name) && matches(name, info, file: file) && matchesText(url, isRegular: isRegular) {
                state.withLock { $0.found.append(url) }
            }
            state.withLock { $0.scannedCount += 1 }
            if isFolder, query.depth.map({ level < $0 }) ?? true {
                walk(url, level: level + 1)
            }
        }
    }

    private func matchesName(_ name: String) -> Bool {
        guard let nameRegex else { return FileMask.matches(name, query.masks) }
        return nameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Only regular files have a text; one that cannot be read (or is too big)
    /// neither contains the text nor goes without it.
    private func matchesText(_ url: URL, isRegular: Bool) -> Bool {
        guard let text else { return true }
        guard isRegular, let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count <= Self.textSearchLimit else { return false }
        return text.matches(data) != query.notContaining
    }

    /// The date, size and attribute conditions. `info` is the item itself (a
    /// symbolic link is not followed), `file` the regular file it is or points to.
    private func matches(_ name: String, _ info: stat, file: stat?) -> Bool {
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        if let after = query.modifiedAfter, modified < after { return false }
        if let before = query.modifiedBefore, modified >= before { return false }
        if let size = query.size {
            guard let file, size.matches(Int64(file.st_size)) else { return false }
        }
        for (attribute, required) in query.attributes {
            let has = switch attribute {
            case .folder: info.st_mode & S_IFMT == S_IFDIR
            case .hidden: name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0
            case .locked: info.st_flags & UInt32(UF_IMMUTABLE) != 0
            case .symbolicLink: info.st_mode & S_IFMT == S_IFLNK
            case .executable: file.map { $0.st_mode & 0o111 != 0 } ?? false
            }
            if has != required { return false }
        }
        return true
    }
}

/// The text looked for in a file's contents. Bytes are looked for as they are
/// whenever they can be (hex, or a case-sensitive text as each encoding writes it);
/// otherwise the contents are decoded in each encoding in turn.
nonisolated private struct TextMatcher: @unchecked Sendable {
    // @unchecked: NSRegularExpression is immutable and may be used from any thread.
    private enum Kind {
        case bytes([Data])
        case caseInsensitive(String)
        case regex(NSRegularExpression)
    }

    private let kind: Kind
    private let encodings: [TextEncoding]

    init(_ query: FileSearch.Query) throws(FileSearch.QueryError) {
        encodings = query.encodings
        if query.isHex {
            guard let bytes = Self.bytes(hex: query.text) else { throw .hex }
            kind = .bytes([bytes])
        } else if query.textIsRegex || query.wholeWords {
            let pattern = query.textIsRegex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
            guard let regex = try? NSRegularExpression(pattern: query.wholeWords ? "\\b(?:\(pattern))\\b" : pattern,
                                                       options: query.caseSensitive ? [] : .caseInsensitive) else {
                throw .textRegex
            }
            kind = .regex(regex)
        } else if query.caseSensitive {
            kind = .bytes(query.encodings.flatMap { TextDecoding.encoded(query.text, as: $0) })
        } else {
            kind = .caseInsensitive(query.text)
        }
    }

    func matches(_ data: Data) -> Bool {
        switch kind {
        case .bytes(let sequences):
            return sequences.contains { data.range(of: $0) != nil }
        case .caseInsensitive(let text):
            return encodings.contains { TextDecoding.decode(data, as: $0).text.range(of: text, options: .caseInsensitive) != nil }
        case .regex(let regex):
            return encodings.contains { encoding in
                let text = TextDecoding.decode(data, as: encoding).text
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    /// "50 4B 03 04", "504b0304": spaces between the bytes or none.
    private static func bytes(hex: String) -> Data? {
        let digits = hex.filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
