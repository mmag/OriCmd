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

    private static let writableExtensions: Set<String> = ["zip", "jar", "tar", "tgz", "tbz", "tbz2", "txz", "7z"]
    private static let writableSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz"]

    static func isWritable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return writableSuffixes.contains(where: name.hasSuffix) || writableExtensions.contains(url.pathExtension.lowercased())
    }

    @concurrent
    static func apply(_ edit: Edit, to archive: URL, progress: TransferProgress) async throws {
        let manager = FileManager.default
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
            guard !newName.isEmpty, !newName.contains("/"), !manager.fileExists(atPath: target.path) else {
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
        _ = try manager.replaceItemAt(archive, withItemAt: packed)
    }
}
