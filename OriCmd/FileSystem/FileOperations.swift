import AppKit

/// Simple single-step file operations. Long running copy/move lives elsewhere.
enum FileOperations {
    /// Creates `name` (may contain "/" for nested folders) inside `directory`.
    static func createDirectory(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Renames within the same directory. Allows case-only renames, refuses to
    /// replace another existing item.
    static func rename(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let target = url.deletingLastPathComponent().appending(path: newName)
        var source = stat()
        var existing = stat()
        if lstat(target.path, &existing) == 0, lstat(url.path, &source) == 0,
           existing.st_ino != source.st_ino || existing.st_dev != source.st_dev {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        }
        guard Darwin.rename(url.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return target
    }

    /// Moves items to the Trash.
    static func moveToTrash(_ urls: [URL]) async throws {
        _ = try await NSWorkspace.shared.recycle(urls)
    }

    /// Deletes items permanently, off the main thread.
    static func deletePermanently(_ urls: [URL]) async throws {
        try await Task.detached {
            for url in urls {
                try FileManager.default.removeItem(at: url)
            }
        }.value
    }
}
