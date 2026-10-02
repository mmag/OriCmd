import CryptoKit
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
        /// Only files that have the same name, size or contents as another one found.
        var duplicates: Duplicates?
    }

    struct Duplicates: Sendable {
        var sameName = false
        var sameSize = false
        var sameContents = false
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
        /// Duplicates, when looked for: the files alike, in the order found; `found`
        /// has them all.
        var groups: [[URL]] = []
        var scannedCount = 0
        /// Files whose contents were read to compare them.
        var comparedCount = 0
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
        var candidates: [Candidate] = []
        walk(query.root, level: 0, candidates: &candidates)
        if let duplicates = query.duplicates {
            let groups = duplicateGroups(candidates, duplicates)
            if !isCancelled {
                state.withLock {
                    $0.groups = groups
                    $0.found = groups.flatMap { $0 }
                }
            }
        }
        state.withLock { $0.isFinished = true }
    }

    private var isCancelled: Bool { state.withLock { $0.isCancelled } }

    /// A regular file found while looking for duplicates.
    private struct Candidate {
        let url: URL
        let name: String
        let size: Int64
        let file: [UInt64]
        let index: Int
    }

    /// `level`: how many subfolders below the root `directory` is. Looking for
    /// duplicates, the regular files found go to `candidates` to be compared.
    private func walk(_ directory: URL, level: Int, candidates: inout [Candidate]) {
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
                if query.duplicates == nil {
                    state.withLock { $0.found.append(url) }
                } else if info.st_mode & S_IFMT == S_IFREG {
                    candidates.append(Candidate(url: url, name: name, size: Int64(info.st_size),
                                                file: [UInt64(info.st_dev), info.st_ino], index: candidates.count))
                }
            }
            state.withLock { $0.scannedCount += 1 }
            if isFolder, query.depth.map({ level < $0 }) ?? true {
                walk(url, level: level + 1, candidates: &candidates)
            }
        }
    }

    /// The beginning of files compared first: most different files differ there.
    private static let headSize = 64 * 1024

    /// Groups of two or more files alike. Hard links to one file are that file
    /// once; empty files are not compared by size or contents.
    private func duplicateGroups(_ candidates: [Candidate], _ options: Duplicates) -> [[URL]] {
        var seen = Set<[UInt64]>()
        var groups = [candidates.filter { seen.insert($0.file).inserted }]
        if options.sameName {
            groups = split(groups) { $0.name.precomposedStringWithCanonicalMapping.lowercased() }
        }
        if options.sameSize || options.sameContents {
            groups = split(groups.map { $0.filter { $0.size > 0 } }) { $0.size }
        }
        if options.sameContents {
            groups = split(groups) { digest($0.url, limit: Self.headSize) }
            // Files alike as far as their beginning: the rest is compared for the bigger ones.
            groups = split(groups) { $0.size <= Self.headSize ? Data() : digest($0.url, limit: nil) }
        }
        return groups.sorted { $0[0].index < $1[0].index }.map { $0.map(\.url) }
    }

    /// Splits each group by `key` (nil: the file is left out), keeping the groups
    /// of two or more, each in the order the files were found.
    private func split<Key: Hashable>(_ groups: [[Candidate]], by key: (Candidate) -> Key?) -> [[Candidate]] {
        groups.flatMap { group in
            Dictionary(grouping: group.compactMap { candidate in key(candidate).map { ($0, candidate) } }, by: \.0)
                .values.map { $0.map(\.1) }
        }.filter { $0.count > 1 }
    }

    /// SHA-256 of the file's first `limit` bytes (nil: all of it); nil when it
    /// cannot be read or the search is stopped.
    private func digest(_ url: URL, limit: Int?) -> Data? {
        guard !isCancelled, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard !isCancelled else { return nil }
            let read: Data?
            do {
                read = try handle.read(upToCount: min(1 << 20, remaining))
            } catch {
                return nil
            }
            // No data (nil) at the end of the file.
            guard let chunk = read, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        state.withLock { $0.comparedCount += 1 }
        return Data(hasher.finalize())
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
