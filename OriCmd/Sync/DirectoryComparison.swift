import Foundation

/// Size and modification date of one side of a compared file.
nonisolated struct ComparedFile: Sendable {
    let size: Int64
    let modified: Date
    /// Empty folders are compared too, so they are created on the other side.
    var isFolder = false
}

/// What synchronizing does with a file present in one or both folders.
nonisolated enum SyncAction: Sendable {
    case toRight, toLeft, equal, different, skip
}

/// A file (by path relative to the compared folders) and its two sides.
nonisolated struct SyncItem: Sendable {
    let path: String
    let left: ComparedFile?
    let right: ComparedFile?
    var action: SyncAction
}

/// Recursive folder comparison for "Synchronize directories".
nonisolated enum DirectoryComparison {
    /// Dates closer than this count as equal (FAT and network shares round them).
    static let dateTolerance: TimeInterval = 2

    @concurrent
    static func compare(left: URL, right: URL, subfolders: Bool, byContent: Bool,
                        isCancelled: @Sendable () -> Bool) async -> [SyncItem] {
        var leftFiles: [String: ComparedFile] = [:]
        var rightFiles: [String: ComparedFile] = [:]
        collect(left, prefix: "", subfolders: subfolders, into: &leftFiles, isCancelled: isCancelled)
        collect(right, prefix: "", subfolders: subfolders, into: &rightFiles, isCancelled: isCancelled)

        let paths = Set(leftFiles.keys).union(rightFiles.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return paths.map { path in
            let l = leftFiles[path]
            let r = rightFiles[path]
            return SyncItem(path: path, left: l, right: r, action: action(path, l, r, left, right, byContent))
        }
    }

    private static func action(_ path: String, _ left: ComparedFile?, _ right: ComparedFile?,
                               _ leftRoot: URL, _ rightRoot: URL, _ byContent: Bool) -> SyncAction {
        guard let left else { return .toLeft }
        guard let right else { return .toRight }
        if left.isFolder || right.isFolder {
            return left.isFolder == right.isFolder ? .equal : .different
        }
        if byContent && left.size == right.size {
            return sameContent(leftRoot.appending(path: path), rightRoot.appending(path: path)) ? .equal : .different
        }
        let difference = left.modified.timeIntervalSince(right.modified)
        if abs(difference) <= dateTolerance {
            return left.size == right.size ? .equal : .different
        }
        return difference > 0 ? .toRight : .toLeft
    }

    private static func collect(_ folder: URL, prefix: String, subfolders: Bool,
                                into files: inout [String: ComparedFile], isCancelled: @Sendable () -> Bool) {
        guard !isCancelled(), let names = try? DirectoryListing.names(in: folder) else { return }
        for name in names {
            let url = folder.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if info.st_mode & S_IFMT == S_IFDIR {
                guard subfolders else { continue }
                if (try? DirectoryListing.names(in: url))?.isEmpty == true {
                    files[path] = ComparedFile(size: 0, modified: .distantPast, isFolder: true)
                } else {
                    collect(url, prefix: path, subfolders: true, into: &files, isCancelled: isCancelled)
                }
            } else {
                files[path] = ComparedFile(
                    size: Int64(info.st_size),
                    modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                )
            }
        }
    }

    private static func sameContent(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? FileHandle(forReadingFrom: a),
              let second = try? FileHandle(forReadingFrom: b) else { return false }
        defer {
            try? first.close()
            try? second.close()
        }
        while true {
            let chunkA = (try? first.read(upToCount: 1 << 20)) ?? Data()
            let chunkB = (try? second.read(upToCount: 1 << 20)) ?? Data()
            if chunkA != chunkB { return false }
            if chunkA.isEmpty { return true }
        }
    }
}
