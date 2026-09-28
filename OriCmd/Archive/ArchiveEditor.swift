import Foundation

/// Changes archives by unpacking them into a temporary folder, applying the
/// change there and packing everything again with `bsdtar`; the original is
/// then replaced atomically. Works for the formats `bsdtar` can write.
nonisolated enum ArchiveEditor {
    enum Edit: Sendable {
        /// Copies files and folders into `folder` ("" is the archive root).
        case add([URL], folder: String)
        case delete([String])
        case makeFolder(String)
        case rename(String, to: String)
    }

    static func isWritable(_ url: URL) -> Bool {
        ArchiveWriter.formatOptions(for: url.lastPathComponent) != nil
    }

    /// Changes of one archive run one after another: each unpacks the whole
    /// archive, so two at once would lose the first one's change.
    @concurrent
    static func apply(_ edit: Edit, to archive: URL, progress: TransferProgress) async throws {
        try await SerialTasks.shared.run(archive.standardizedFileURL.path) {
            try await applyNow(edit, to: archive, progress: progress)
        }
    }

    @concurrent
    private static func applyNow(_ edit: Edit, to archive: URL, progress: TransferProgress) async throws {
        let manager = FileManager.default
        let before = fingerprint(of: archive)
        let workspace = manager.temporaryDirectory.appending(path: "OriCmd-edit-\(UUID().uuidString)")
        let content = workspace.appending(path: "content")
        try manager.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }

        let total = try ArchiveReader.entries(of: archive).reduce(Int64(0)) { $0 + $1.size }
        progress.update { $0.totalBytes = total }
        try await ArchiveReader.extract(archive, paths: [], base: "", to: content, progress: progress)
        if progress.isCancelled { throw CancellationError() }

        switch edit {
        case .add(let sources, let folder):
            let target = folder.isEmpty ? content : content.appending(path: folder)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            for source in sources {
                let destination = target.appending(path: source.lastPathComponent)
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: source, to: destination)
            }
        case .delete(let paths):
            for path in paths {
                try manager.removeItem(at: content.appending(path: path))
            }
        case .makeFolder(let path):
            try manager.createDirectory(at: content.appending(path: path), withIntermediateDirectories: true)
        case .rename(let path, let newName):
            let source = content.appending(path: path)
            let target = source.deletingLastPathComponent().appending(path: newName)
            // A name differing only in letter case is the same entry on this file system.
            var existing = stat()
            var current = stat()
            let taken = lstat(target.path, &existing) == 0 && lstat(source.path, &current) == 0
                && existing.st_ino != current.st_ino
            guard !newName.isEmpty, !newName.contains("/"), !taken else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: newName])
            }
            try manager.moveItem(at: source, to: target)
        }

        let names = try DirectoryListing.names(in: content)
        guard !names.isEmpty else {
            throw ArchiveError(message: String(localized: "The archive would become empty."))
        }
        let packed = workspace.appending(path: archive.lastPathComponent)
        try await ArchiveWriter.pack(names, in: content, to: packed, progress: progress)
        guard fingerprint(of: archive) == before else {
            throw ArchiveError(message: String(localized:
                "\u{201C}\(archive.lastPathComponent)\u{201D} was changed by another program meanwhile; nothing was written."))
        }
        _ = try manager.replaceItemAt(archive, withItemAt: packed)
    }

    /// Size and modification time, to notice changes made meanwhile.
    private static func fingerprint(of url: URL) -> [Int64] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [] }
        return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
    }
}

/// Runs the operations on one key (an archive path, a server) one at a time, in order.
actor SerialTasks {
    static let shared = SerialTasks()
    private var tails: [String: Task<Void, Never>] = [:]

    func run(_ key: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tails[key]
        let task = Task {
            await previous?.value
            try await body()
        }
        tails[key] = Task { _ = try? await task.value }
        try await task.value
    }
}
