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
        /// Also inside archives (by their names: zip, tar.gz, 7z…); not when looking
        /// for duplicates.
        var inArchives = false
    }

    /// A file or folder found: on disk, or inside the archive `url` at `entry`.
    struct Found: Sendable, Hashable {
        let url: URL
        var entry: String?

        /// "…/archive.zip/folder/file.txt" for an entry.
        var path: String { entry.map { url.path + "/" + $0 } ?? url.path }
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
        var found: [Found] = []
        /// Duplicates, when looked for: the files alike, in the order found; `found`
        /// has them all.
        var groups: [[Found]] = []
        var scannedCount = 0
        /// Files whose contents were read to compare them.
        var comparedCount = 0
        var isCancelled = false
        var isFinished = false
    }

    /// Larger files are not searched for text.
    private static let textSearchLimit = 256 * 1024 * 1024
    /// Larger files in archives are not searched for text (they are unpacked in memory).
    private static let archivedTextSearchLimit = 64 * 1024 * 1024

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
            if matches(Item(name: name, info, file: file)) && matchesText(url, isRegular: isRegular) {
                if query.duplicates == nil {
                    state.withLock { $0.found.append(Found(url: url)) }
                } else if info.st_mode & S_IFMT == S_IFREG {
                    candidates.append(Candidate(url: url, name: name, size: Int64(info.st_size),
                                                file: [UInt64(info.st_dev), info.st_ino], index: candidates.count))
                }
            }
            state.withLock { $0.scannedCount += 1 }
            if query.inArchives, query.duplicates == nil, info.st_mode & S_IFMT == S_IFREG, ArchiveReader.isArchive(name) {
                searchArchive(url)
            }
            if isFolder, query.depth.map({ level < $0 }) ?? true {
                walk(url, level: level + 1, candidates: &candidates)
            }
        }
    }

    /// The entries of an archive, by the same conditions; the data of an entry is
    /// unpacked only when the text is to be looked for in it. An archive that
    /// cannot be read (damaged, encrypted) is passed over.
    private func searchArchive(_ url: URL) {
        try? ArchiveReader.scan(url, dataLimit: Self.archivedTextSearchLimit, wantsData: { entry in
            text != nil && matches(Item(entry))
        }, visit: { entry, data in
            if isCancelled { return false }
            let found = matches(Item(entry)) && (text.map { text in
                !entry.isDirectory && data.map { text.matches($0) != query.notContaining } ?? false
            } ?? true)
            state.withLock {
                if found { $0.found.append(Found(url: url, entry: entry.path)) }
                $0.scannedCount += 1
            }
            return true
        })
    }

    /// The beginning of files compared first: most different files differ there.
    private static let headSize = 64 * 1024

    /// Groups of two or more files alike. Hard links to one file are that file
    /// once; empty files are not compared by size or contents.
    private func duplicateGroups(_ candidates: [Candidate], _ options: Duplicates) -> [[Found]] {
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
        return groups.sorted { $0[0].index < $1[0].index }.map { $0.map { Found(url: $0.url) } }
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

    /// What the conditions look at, of a file or folder on disk or in an archive.
    private struct Item {
        let name: String
        let modified: Date
        /// Of files only (a symbolic link: of its target).
        let size: Int64?
        let attributes: Set<Attribute>

        /// `info`: the item itself (a symbolic link is not followed); `file`: the
        /// regular file it is or points to.
        init(name: String, _ info: stat, file: stat?) {
            self.name = name
            modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            size = file.map { Int64($0.st_size) }
            attributes = Set(Attribute.allCases.filter { attribute in
                switch attribute {
                case .folder: info.st_mode & S_IFMT == S_IFDIR
                case .hidden: name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0
                case .locked: info.st_flags & UInt32(UF_IMMUTABLE) != 0
                case .symbolicLink: info.st_mode & S_IFMT == S_IFLNK
                case .executable: file.map { $0.st_mode & 0o111 != 0 } ?? false
                }
            })
        }

        /// An entry of an archive: never locked, hidden by its name only.
        init(_ entry: ArchiveEntry) {
            let name = (entry.path as NSString).lastPathComponent
            self.name = name
            modified = entry.modified
            let isFile = !entry.isDirectory && !entry.isSymbolicLink
            size = isFile ? entry.size : nil
            attributes = Set(Attribute.allCases.filter { attribute in
                switch attribute {
                case .folder: entry.isDirectory
                case .hidden: name.hasPrefix(".")
                case .locked: false
                case .symbolicLink: entry.isSymbolicLink
                case .executable: isFile && entry.mode & 0o111 != 0
                }
            })
        }
    }

    /// The name, date, size and attribute conditions.
    private func matches(_ item: Item) -> Bool {
        guard matchesName(item.name) else { return false }
        if let after = query.modifiedAfter, item.modified < after { return false }
        if let before = query.modifiedBefore, item.modified >= before { return false }
        if let size = query.size {
            guard let itemSize = item.size, size.matches(itemSize) else { return false }
        }
        return query.attributes.allSatisfy { attribute, required in item.attributes.contains(attribute) == required }
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
