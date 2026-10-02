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
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(query: Query) {
        self.query = query
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
            if FileMask.matches(name, query.masks) && matches(name, info, file: file)
                && (query.text.isEmpty || (isRegular && contains(url))) {
                state.withLock { $0.found.append(url) }
            }
            state.withLock { $0.scannedCount += 1 }
            if isFolder, query.depth.map({ level < $0 }) ?? true {
                walk(url, level: level + 1)
            }
        }
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

    private func contains(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count <= Self.textSearchLimit else { return false }
        if query.caseSensitive {
            return data.range(of: Data(query.text.utf8)) != nil
        }
        return String(decoding: data, as: UTF8.self).range(of: query.text, options: .caseInsensitive) != nil
    }
}
