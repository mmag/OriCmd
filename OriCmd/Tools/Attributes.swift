import Foundation

/// A change of Unix permissions, file flags and modification date.
/// `nil` values (and permission bits not listed) are left as they are.
nonisolated struct AttributeChange: Sendable {
    var permissions: [mode_t: Bool] = [:]
    var hidden: Bool?
    var locked: Bool?
    var modified: Date?
    var includesSubfolders = false

    static let permissionBits: [mode_t] = [
        S_IRUSR, S_IWUSR, S_IXUSR, S_IRGRP, S_IWGRP, S_IXGRP, S_IROTH, S_IWOTH, S_IXOTH,
    ]

    @concurrent
    func apply(to urls: [URL], progress: TransferProgress) async throws {
        for url in urls {
            try apply(to: url, progress: progress)
        }
    }

    private func apply(to url: URL, progress: TransferProgress) throws {
        if progress.isCancelled { throw CancellationError() }
        let path = url.path
        progress.update { $0.source = path }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw TransferError.posix(path) }
        let isSymlink = info.st_mode & S_IFMT == S_IFLNK

        // A locked file cannot be changed: unlock first, lock last.
        var flags = info.st_flags
        if locked == false || (locked == nil && flags & UInt32(UF_IMMUTABLE) != 0 && needsWrite) {
            flags &= ~UInt32(UF_IMMUTABLE)
            try setFlags(flags, path)
        }
        if !isSymlink {
            var mode = info.st_mode & 0o7777
            for (bit, on) in permissions {
                mode = on ? mode | bit : mode & ~bit
            }
            if mode != info.st_mode & 0o7777, chmod(path, mode) != 0 {
                throw TransferError.posix(path)
            }
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
            }
        }
        if let hidden {
            flags = hidden ? flags | UInt32(UF_HIDDEN) : flags & ~UInt32(UF_HIDDEN)
        }
        let wasLocked = info.st_flags & UInt32(UF_IMMUTABLE) != 0
        if locked == true || (locked == nil && wasLocked) {
            flags |= UInt32(UF_IMMUTABLE)
        }
        if flags != info.st_flags {
            try setFlags(flags, path)
        }

        if includesSubfolders && info.st_mode & S_IFMT == S_IFDIR {
            for name in try DirectoryListing.names(in: url) {
                try apply(to: url.appending(path: name), progress: progress)
            }
        }
    }

    private var needsWrite: Bool {
        !permissions.isEmpty || modified != nil || hidden != nil
    }

    private func setFlags(_ flags: UInt32, _ path: String) throws {
        guard lchflags(path, flags) == 0 else { throw TransferError.posix(path) }
    }
}
