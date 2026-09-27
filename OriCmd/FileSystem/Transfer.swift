import Foundation
import os

/// What to copy or move and where.
nonisolated struct TransferJob: Sendable {
    enum Kind: Sendable {
        case copy, move
    }

    let kind: Kind
    let sources: [URL]
    /// The folder that receives the items.
    let destination: URL
    /// A new name, when a single item is copied or moved under another name.
    let newName: String?
}

nonisolated enum ConflictDecision: Sendable {
    case overwrite, overwriteAll, skip, skipAll, cancel
}

nonisolated struct TransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func posix(_ path: String) -> TransferError {
        TransferError(message: "\(path): \(String(cString: strerror(errno)))")
    }
}

/// Progress shared between the transfer thread and the UI, which polls it.
nonisolated final class TransferProgress: Sendable {
    struct State {
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var fileBytes: Int64 = 0
        var fileDoneBytes: Int64 = 0
        var source = ""
        var target = ""
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var snapshot: State { state.withLock { $0 } }
    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func cancel() {
        update { $0.isCancelled = true }
    }
}

/// Copies or moves files and folders recursively on a background thread.
///
/// Files are copied with `copyfile(3)`, keeping metadata, extended attributes
/// and ACLs, and cloned instantly on APFS where possible. Moves within a volume
/// are renames; across volumes they are a copy followed by a delete.
/// Folders are merged into existing folders of the same name.
nonisolated final class TransferEngine {
    typealias ConflictHandler = @Sendable (_ source: URL, _ target: URL) async -> ConflictDecision

    private let job: TransferJob
    private let progress: TransferProgress
    private let resolveConflict: ConflictHandler
    private var overwriteAll = false
    private var skipAll = false

    init(job: TransferJob, progress: TransferProgress, resolveConflict: @escaping ConflictHandler) {
        self.job = job
        self.progress = progress
        self.resolveConflict = resolveConflict
    }

    /// Returns the sources that were fully transferred.
    @concurrent
    func run() async throws -> [URL] {
        let total = job.sources.reduce(Int64(0)) { $0 + Self.totalSize(of: $1) }
        progress.update { $0.totalBytes = total }

        try FileManager.default.createDirectory(at: job.destination, withIntermediateDirectories: true)
        var done: [URL] = []
        for source in job.sources {
            let target = job.destination.appending(path: job.newName ?? source.lastPathComponent)
            if try await transfer(source, to: target) {
                done.append(source)
            }
        }
        return done
    }

    /// Returns false if the item (or something inside it) was skipped.
    private func transfer(_ source: URL, to target: URL) async throws -> Bool {
        if progress.isCancelled { throw CancellationError() }

        let sourcePath = source.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if sourcePath == targetPath {
            if job.kind == .move { return true }
            throw TransferError(message: String(localized: "Cannot copy \u{201C}\(source.lastPathComponent)\u{201D} onto itself."))
        }
        if targetPath.hasPrefix(sourcePath + "/") {
            throw TransferError(message: String(localized: "Cannot copy \u{201C}\(source.lastPathComponent)\u{201D} into itself."))
        }

        var sourceInfo = stat()
        guard lstat(sourcePath, &sourceInfo) == 0 else { throw TransferError.posix(sourcePath) }
        let isFolder = sourceInfo.st_mode & S_IFMT == S_IFDIR

        var targetInfo = stat()
        let targetExists = lstat(targetPath, &targetInfo) == 0
        let targetIsFolder = targetExists && targetInfo.st_mode & S_IFMT == S_IFDIR

        if isFolder && targetIsFolder {
            return try await merge(source, into: target)
        }
        if targetExists {
            switch try await decide(source, target) {
            case .overwrite:
                try FileManager.default.removeItem(at: target)
            case .skip:
                progress.update { $0.doneBytes += Self.totalSize(of: source) }
                return false
            }
        }

        if job.kind == .move {
            if Darwin.rename(sourcePath, targetPath) == 0 {
                progress.update { $0.doneBytes += Self.totalSize(of: source) }
                return true
            }
            guard errno == EXDEV else { throw TransferError.posix(sourcePath) }
        }

        if isFolder {
            guard mkdir(targetPath, sourceInfo.st_mode & 0o7777 | S_IRWXU) == 0 else {
                throw TransferError.posix(targetPath)
            }
            return try await merge(source, into: target)
        }

        try copyFile(sourcePath, to: targetPath, size: Int64(sourceInfo.st_size))
        if job.kind == .move, unlink(sourcePath) != 0 {
            throw TransferError.posix(sourcePath)
        }
        return true
    }

    /// Transfers the contents of `source` into the existing folder `target`.
    private func merge(_ source: URL, into target: URL) async throws -> Bool {
        var complete = true
        for name in try DirectoryListing.names(in: source) {
            let transferred = try await transfer(source.appending(path: name), to: target.appending(path: name))
            complete = complete && transferred
        }
        // Folder attributes (permissions, dates, xattrs) are applied after the contents.
        copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        if job.kind == .move && complete {
            guard rmdir(source.path) == 0 else { throw TransferError.posix(source.path) }
        }
        return complete
    }

    private enum Resolution { case overwrite, skip }

    private func decide(_ source: URL, _ target: URL) async throws -> Resolution {
        if overwriteAll { return .overwrite }
        if skipAll { return .skip }
        switch await resolveConflict(source, target) {
        case .overwrite: return .overwrite
        case .overwriteAll:
            overwriteAll = true
            return .overwrite
        case .skip: return .skip
        case .skipAll:
            skipAll = true
            return .skip
        case .cancel: throw CancellationError()
        }
    }

    private func copyFile(_ source: String, to target: String, size: Int64) throws {
        progress.update {
            $0.source = source
            $0.target = target
            $0.fileBytes = size
            $0.fileDoneBytes = 0
        }

        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let progress = Unmanaged<TransferProgress>.fromOpaque(context).takeUnretainedValue()
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                let bytes = Int64(copied)
                progress.update { $0.fileDoneBytes = bytes }
            }
            return progress.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(progress).toOpaque())

        // COPYFILE_CLONE clones on APFS and falls back to a full copy with metadata.
        let result = copyfile(source, target, state, copyfile_flags_t(COPYFILE_CLONE))
        let failure = errno
        progress.update {
            $0.doneBytes += size
            $0.fileDoneBytes = size
        }
        if result != 0 {
            unlink(target)
            if progress.isCancelled { throw CancellationError() }
            errno = failure
            throw TransferError.posix(source)
        }
    }

    /// Total size of a file, or of all files inside a folder (symlinks are not followed).
    static func totalSize(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_size) }
        let names = (try? DirectoryListing.names(in: url)) ?? []
        return names.reduce(Int64(0)) { $0 + totalSize(of: url.appending(path: $1)) }
    }
}
