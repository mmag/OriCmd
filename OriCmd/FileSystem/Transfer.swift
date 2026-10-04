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
    var options = TransferOptions()
}

/// One side of a "File already exists" question: what the user needs to decide.
nonisolated struct ConflictItem: Sendable {
    /// Shown as is: a local path, or "host:/path" on a server.
    let path: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let modified: Date?
    /// The existing file is smaller than the one coming from or going to a server:
    /// the transfer may go on from where it stopped.
    var resumable = false

    static func local(_ url: URL) -> ConflictItem {
        var info = stat()
        let found = lstat(url.path, &info) == 0
        return ConflictItem(path: url.path, name: url.lastPathComponent,
                            isFolder: found && info.st_mode & S_IFMT == S_IFDIR,
                            size: found ? Int64(info.st_size) : nil,
                            modified: found ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil)
    }

    /// An entry of a server listing (the local file system knows nothing about it).
    static func remote(_ item: FileItem) -> ConflictItem {
        ConflictItem(path: (item.url.host().map { $0 + ":" } ?? "") + item.url.path(percentEncoded: false),
                     name: item.name, isFolder: item.isDirectory,
                     size: item.isDirectory ? nil : item.size, modified: item.modified)
    }
}

nonisolated enum ConflictDecision: Sendable {
    case overwrite, overwriteAll, skip, skipAll, overwriteAllOlder, cancel
    /// Go on with an existing smaller file (offered for servers only).
    case resume
}

/// What to do about an item that could not be copied or moved.
nonisolated enum ErrorDecision: Sendable {
    case skip, retry, cancel
}

/// The questions a transfer asks while it runs, answered in its progress window.
nonisolated struct TransferPrompts: Sendable {
    /// "File already exists".
    let resolveConflict: TransferEngine.ConflictHandler
    /// An item that failed: skip it, try it again or stop the whole operation.
    let resolveError: TransferEngine.ErrorHandler
}

nonisolated struct TransferError: LocalizedError {
    let message: String
    /// The destination lets nothing take this name.
    var refusesName = false
    var errorDescription: String? { message }

    static func posix(_ path: String) -> TransferError {
        TransferError(message: "\(path): \(String(cString: strerror(errno)))")
    }

    /// A rename or mkdir that made `path` failed: ENOENT although `existing` is
    /// there means the destination refuses the name (a Samba server's "veto files"
    /// hide .DS_Store, Thumbs.db and the like, and let nothing take those names).
    static func creating(_ path: String, although existing: String) -> TransferError {
        let failure = errno
        guard failure == ENOENT, access(existing, F_OK) == 0 else {
            errno = failure
            return posix(path)
        }
        return TransferError(message: String(localized: "\(path): the server does not accept this name."), refusesName: true)
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
        var isPaused = false
        /// Bytes per second; nil: as fast as it goes.
        var speedLimit: Int64?
        /// Since when the bytes counted against the speed limit are counted.
        fileprivate var paceStart: TimeInterval = 0
        fileprivate var pacedBytes: Int64 = 0
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

    /// Sets the bytes done of the current file, counting them in the whole too;
    /// returns how many were added.
    func advanceFile(to bytes: Int64) -> Int64 {
        state.withLock { state in
            let added = bytes - state.fileDoneBytes
            state.fileDoneBytes = bytes
            state.doneBytes += added
            return added
        }
    }

    /// Pauses or goes on; the speed limit counts afresh after a pause.
    func setPaused(_ paused: Bool) {
        update {
            $0.isPaused = paused
            $0.paceStart = 0
        }
    }

    func setSpeedLimit(_ limit: Int64?) {
        update {
            $0.speedLimit = limit
            $0.paceStart = 0
        }
    }

    /// Called by the copying thread after `bytes` more were copied: waits while
    /// the operation is paused, and as long as the bytes so far are ahead of the
    /// speed limit. Returns at once when it is cancelled.
    func pace(_ bytes: Int64) {
        while state.withLock({ $0.isPaused && !$0.isCancelled }) {
            usleep(100_000)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let wait: TimeInterval = state.withLock { state in
            guard let limit = state.speedLimit, limit > 0 else { return 0 }
            if state.paceStart == 0 {
                state.paceStart = now
                state.pacedBytes = 0
            }
            state.pacedBytes += bytes
            return Double(state.pacedBytes) / Double(limit) - (now - state.paceStart)
        }
        var left = wait
        while left > 0, !isCancelled {
            let step = min(left, 0.1)
            usleep(useconds_t(step * 1_000_000))
            left -= step
        }
    }
}

/// Copies or moves files and folders recursively on a background thread.
///
/// Files are copied with `copyfile(3)`, keeping metadata, extended attributes
/// and ACLs, and cloned instantly on APFS where possible. Moves within a volume
/// are renames; across volumes they are a copy followed by a delete.
/// Folders are merged into existing folders of the same name. The job's
/// options add Total Commander's overwrite modes, a file type filter, renaming
/// by mask and verification.
nonisolated final class TransferEngine {
    typealias ConflictHandler = @Sendable (_ source: ConflictItem, _ target: ConflictItem) async -> ConflictDecision
    typealias ErrorHandler = @Sendable (_ message: String) async -> ErrorDecision

    private let job: TransferJob
    private let progress: TransferProgress
    private let prompts: TransferPrompts
    /// Starts as chosen in the dialog; "Overwrite All" etc. in the prompt change it.
    private var mode: OverwriteMode
    private var options: TransferOptions { job.options }

    private let reportsTotal: Bool

    /// With `reportsTotal` false the caller has set `totalBytes` for a batch of jobs.
    init(job: TransferJob, progress: TransferProgress, reportsTotal: Bool = true, prompts: TransferPrompts) {
        self.job = job
        self.progress = progress
        self.reportsTotal = reportsTotal
        self.prompts = prompts
        mode = job.options.overwrite
    }

    /// Returns the sources that were fully transferred.
    @concurrent
    func run() async throws -> [URL] {
        if reportsTotal {
            let total = job.sources.reduce(Int64(0)) { $0 + Self.totalSize(of: $1) }
            progress.update { $0.totalBytes = total }
        }

        try FileManager.default.createDirectory(at: job.destination, withIntermediateDirectories: true)
        var done: [URL] = []
        for source in job.sources {
            let target = job.newName.map { job.destination.appending(path: $0) } ?? targetURL(for: source, in: job.destination)
            if try await transfer(source, to: target, insideIncludedFolder: false, topLevel: true) {
                done.append(source)
            }
        }
        return done
    }

    /// Where `source` goes in `folder`: files are renamed by the target mask.
    private func targetURL(for source: URL, in folder: URL) -> URL {
        let name = source.lastPathComponent
        guard let mask = options.renameMask, !Self.isFolder(source.path) else { return folder.appending(path: name) }
        return folder.appending(path: mask.apply(to: name))
    }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// What Finder and Windows Explorer keep in folders for themselves (view
    /// settings, thumbnails), which file servers are often set to refuse.
    private static func isFolderMetadata(_ name: String) -> Bool {
        [".ds_store", "thumbs.db", "desktop.ini"].contains(name.lowercased())
    }

    /// A test run's stand-in for a server's "veto files": the names in `ORICMD_VETO`
    /// ("/.DS_Store/Thumbs.db/", any case) cannot be created, with ENOENT as there.
    private static func vetoed(_ path: String) -> Bool {
        #if DEBUG
        guard let list = ProcessInfo.processInfo.environment["ORICMD_VETO"],
              list.lowercased().split(separator: "/").contains(Substring((path as NSString).lastPathComponent.lowercased()))
        else { return false }
        errno = ENOENT
        return true
        #else
        false
        #endif
    }

    /// Returns false if the item (or something inside it) was skipped or filtered out.
    /// `topLevel`: one of the items the user chose (not something inside a folder).
    /// An item that fails is asked about: skipped, tried again, or the whole
    /// operation stops; what failed inside a folder is asked about by itself.
    private func transfer(_ source: URL, to target: URL, insideIncludedFolder: Bool,
                          topLevel: Bool = false) async throws -> Bool {
        let doneBefore = progress.snapshot.doneBytes
        while true {
            do {
                return try await transferItem(source, to: target, insideIncludedFolder: insideIncludedFolder,
                                              topLevel: topLevel)
            } catch let error as CancellationError {
                throw error
            } catch {
                let message = error is TransferError ? error.localizedDescription
                    : "\(source.standardizedFileURL.path): \(error.localizedDescription)"
                switch await prompts.resolveError(message) {
                case .skip:
                    let size = Self.totalSize(of: source)
                    progress.update { $0.doneBytes = max($0.doneBytes, doneBefore + size) }
                    return false
                case .retry:
                    // A file counts afresh; a folder keeps what its contents counted.
                    if !Self.isFolder(source.path) { progress.update { $0.doneBytes = doneBefore } }
                case .cancel:
                    throw CancellationError()
                }
            }
        }
    }

    private func transferItem(_ source: URL, to target: URL, insideIncludedFolder: Bool,
                              topLevel: Bool) async throws -> Bool {
        if progress.isCancelled { throw CancellationError() }
        var target = target

        let sourcePath = source.standardizedFileURL.path
        var sourceInfo = stat()
        guard lstat(sourcePath, &sourceInfo) == 0 else { throw TransferError.posix(sourcePath) }
        let isFolder = sourceInfo.st_mode & S_IFMT == S_IFDIR
        let name = source.lastPathComponent

        // The same file under another path (letter case, /tmp and /private/tmp, a
        // symbolic link to the folder): moving only renames it, copying is refused.
        // Paths cannot tell this; the file system identity can.
        var existing = stat()
        if lstat(target.path, &existing) == 0, existing.st_dev == sourceInfo.st_dev, existing.st_ino == sourceInfo.st_ino {
            guard job.kind == .move else {
                // Inside a folder this is a hard link to the source: nothing to copy.
                if !topLevel { return skipped(source) }
                throw TransferError(message: String(localized: "Cannot copy \u{201C}\(name)\u{201D} onto itself."))
            }
            if source.lastPathComponent != target.lastPathComponent || sourcePath != target.standardizedFileURL.path,
               Darwin.rename(sourcePath, target.path) != 0 {
                throw TransferError.posix(sourcePath)
            }
            return true
        }
        if isFolder, Self.folder(target.deletingLastPathComponent(), isInside: sourceInfo) {
            throw TransferError(message: job.kind == .move
                ? String(localized: "Cannot move \u{201C}\(name)\u{201D} into itself.")
                : String(localized: "Cannot copy \u{201C}\(name)\u{201D} into itself."))
        }

        // Finder's view settings of a folder are not carried over; a move drops them,
        // or its source folder would stay behind for them.
        if options.skipsDSStore, !topLevel, !isFolder, name == ".DS_Store" {
            let size = Int64(sourceInfo.st_size)
            progress.update { $0.doneBytes += size }
            if job.kind == .move { unlink(sourcePath) }
            return true
        }

        // "Only files of this type".
        var insideIncludedFolder = insideIncludedFolder
        if isFolder {
            if options.filter.excludesFolder(name) { return skipped(source) }
            insideIncludedFolder = insideIncludedFolder || options.filter.includesFolder(name)
        } else if !options.filter.includesFile(name, insideIncludedFolder: insideIncludedFolder) {
            return skipped(source)
        }
        if options.skipsUnreadable, access(sourcePath, isFolder ? R_OK | X_OK : R_OK) != 0 {
            return skipped(source)
        }

        var targetInfo = stat()
        let targetExists = lstat(target.path, &targetInfo) == 0
        let targetIsFolder = targetExists && targetInfo.st_mode & S_IFMT == S_IFDIR

        if isFolder && targetIsFolder {
            return try await merge(source, into: target, insideIncludedFolder: insideIncludedFolder, created: false)
        }
        // A file that replaces another file takes its place in one step at the end
        // (rename), so a failed or cancelled copy leaves the old one; a folder is
        // removed first.
        var unlocksTarget = false
        if targetExists {
            switch try await decide(source, target, sourceInfo: sourceInfo, targetInfo: targetInfo) {
            case .overwrite:
                // A locked file is only unlocked at the moment it is replaced (a failed
                // copy leaves it locked); without the option it is refused right away.
                let targetLocked = targetInfo.st_flags & UInt32(UF_IMMUTABLE) != 0
                if targetLocked && !options.overwritesLocked {
                    throw TransferError(message: String(localized:
                        "\u{201C}\(target.lastPathComponent)\u{201D} is locked. Turn on \u{201C}Overwrite/delete locked files\u{201D} to replace it."))
                }
                if isFolder || targetIsFolder {
                    if options.overwritesLocked { Self.unlock(target, recursively: targetIsFolder) }
                    try FileManager.default.removeItem(at: target)
                } else {
                    unlocksTarget = targetLocked
                }
            case .skip:
                return skipped(source)
            case .rename(let newTarget):
                target = newTarget
            case .proceed:
                break
            }
        }
        let targetPath = target.path

        // A whole folder can only be renamed when nothing inside is filtered or renamed.
        if job.kind == .move, !isFolder || (options.filter.isEmpty && options.renameMask == nil) {
            let flags = sourceInfo.st_flags
            if options.overwritesLocked, flags & UInt32(UF_IMMUTABLE) != 0 {
                chflags(sourcePath, flags & ~UInt32(UF_IMMUTABLE))
            }
            // rename(2) replaces an existing file atomically.
            if unlocksTarget { chflags(targetPath, targetInfo.st_flags & ~UInt32(UF_IMMUTABLE)) }
            if Darwin.rename(sourcePath, targetPath) == 0 {
                if flags & UInt32(UF_IMMUTABLE) != 0 { chflags(targetPath, flags) }
                let size = Self.totalSize(of: URL(filePath: targetPath))
                progress.update { $0.doneBytes += size }
                return true
            }
            guard errno == EXDEV else { throw TransferError.posix(sourcePath) }
        }

        if isFolder {
            guard !Self.vetoed(targetPath), mkdir(targetPath, sourceInfo.st_mode & 0o7777 | S_IRWXU) == 0 else {
                throw TransferError.creating(targetPath, although: target.deletingLastPathComponent().path)
            }
            return try await merge(source, into: target, insideIncludedFolder: insideIncludedFolder, created: true)
        }

        // The copy is written under a temporary name next to the target and renamed
        // when complete: an interrupted copy never looks like a finished file.
        // A short fixed-length name: the original may already use the whole 255 bytes.
        let partial = target.deletingLastPathComponent()
            .appending(path: ".oricmd-\(UUID().uuidString.prefix(12)).part").path
        do {
            try copyFile(sourcePath, to: partial, size: Int64(sourceInfo.st_size))
            // Only regular files are read back (a symbolic link is copied as a link).
            if options.verify, sourceInfo.st_mode & S_IFMT == S_IFREG {
                try verify(sourcePath, partial)
            }
            if unlocksTarget { chflags(targetPath, targetInfo.st_flags & ~UInt32(UF_IMMUTABLE)) }
            guard !Self.vetoed(targetPath), Darwin.rename(partial, targetPath) == 0 else {
                throw TransferError.creating(targetPath, although: partial)
            }
        } catch let error as TransferError where error.refusesName && Self.isFolderMetadata(name) {
            // Kept off the server on purpose: left out (Finder or Explorer writes a new
            // one when needed), and the copy goes on; a move removes the original too.
            unlink(partial)
        } catch {
            unlink(partial)
            throw error
        }
        if job.kind == .move {
            if options.overwritesLocked, sourceInfo.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                chflags(sourcePath, sourceInfo.st_flags & ~UInt32(UF_IMMUTABLE))
            }
            guard unlink(sourcePath) == 0 else { throw TransferError.posix(sourcePath) }
        }
        return true
    }

    /// Counts a skipped or filtered-out item as done for the progress.
    private func skipped(_ source: URL) -> Bool {
        let size = Self.totalSize(of: source)
        progress.update { $0.doneBytes += size }
        return false
    }

    /// Transfers the contents of `source` into the folder `target`. A folder
    /// created here that stays empty because of the filter is removed again.
    private func merge(_ source: URL, into target: URL, insideIncludedFolder: Bool, created: Bool) async throws -> Bool {
        var complete = true
        let names: [String]
        do {
            names = try DirectoryListing.names(in: source)
        } catch where options.skipsUnreadable {
            if created { rmdir(target.path) }
            return false
        }
        for name in names {
            let child = source.appending(path: name)
            let transferred = try await transfer(child, to: targetURL(for: child, in: target),
                                                 insideIncludedFolder: insideIncludedFolder)
            complete = complete && transferred
        }
        if created, !options.filter.isEmpty, (try? DirectoryListing.names(in: target))?.isEmpty == true {
            rmdir(target.path)
        } else {
            // Folder attributes (permissions, dates, xattrs) are applied after the contents.
            let flags = options.copiesAttributes ? COPYFILE_METADATA : COPYFILE_STAT
            copyfile(source.path, target.path, nil, copyfile_flags_t(flags))
        }
        if job.kind == .move && complete {
            guard rmdir(source.path) == 0 else { throw TransferError.posix(source.path) }
        }
        return complete
    }

    private enum Resolution {
        case overwrite, skip, proceed
        case rename(URL)
    }

    private func decide(_ source: URL, _ target: URL, sourceInfo: stat, targetInfo: stat) async throws -> Resolution {
        let bothFiles = sourceInfo.st_mode & S_IFMT != S_IFDIR && targetInfo.st_mode & S_IFMT != S_IFDIR
        // A file and a folder of the same name: never decided by an "all" mode,
        // since replacing would delete a whole folder (or put a file over one).
        if !bothFiles {
            if mode == .skipAll { return .skip }
            switch await prompts.resolveConflict(.local(source), .local(target)) {
            case .overwrite, .overwriteAll, .overwriteAllOlder, .resume: return .overwrite
            case .skip, .skipAll: return .skip
            case .cancel: throw CancellationError()
            }
        }
        switch mode {
        case .overwriteAll:
            return .overwrite
        case .skipAll:
            return .skip
        case .renameCopied:
            return .rename(Self.freeName(for: target))
        case .renameTarget:
            let moved = Self.freeName(for: target)
            guard Darwin.rename(target.path, moved.path) == 0 else { throw TransferError.posix(target.path) }
            return .proceed
        case .overwriteOlder where bothFiles:
            return Self.modified(sourceInfo) > Self.modified(targetInfo) ? .overwrite : .skip
        case .copyLarger where bothFiles:
            return sourceInfo.st_size > targetInfo.st_size ? .overwrite : .skip
        case .copySmaller where bothFiles:
            return sourceInfo.st_size < targetInfo.st_size ? .overwrite : .skip
        default:
            break
        }
        // Ask, and for a file meeting a folder in the modes that compare files.
        switch await prompts.resolveConflict(.local(source), .local(target)) {
        case .overwrite, .resume:
            return .overwrite
        case .overwriteAll:
            mode = .overwriteAll
            return .overwrite
        case .skip:
            return .skip
        case .skipAll:
            mode = .skipAll
            return .skip
        case .overwriteAllOlder:
            mode = .overwriteOlder
            return bothFiles && Self.modified(sourceInfo) <= Self.modified(targetInfo) ? .skip : .overwrite
        case .cancel:
            throw CancellationError()
        }
    }

    /// Whether `folder` (or one of the folders above it) is the folder `info`
    /// describes — copying that folder there would copy it into itself.
    private static func folder(_ folder: URL, isInside info: stat) -> Bool {
        var path = folder.standardizedFileURL.path
        while true {
            var current = stat()
            if stat(path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino {
                return true
            }
            guard path != "/", !path.isEmpty else { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private static func modified(_ info: stat) -> Double {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// "name(2).ext", "name(3).ext", … — the first name not taken in the folder.
    static func freeName(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let suffix = dot.map { String(name[$0...]) } ?? ""
        var number = 2
        while true {
            let candidate = folder.appending(path: "\(base)(\(number))\(suffix)")
            var info = stat()
            if lstat(candidate.path, &info) != 0 { return candidate }
            number += 1
        }
    }

    /// Clears the "locked" flag (of everything inside, for a folder).
    private static func unlock(_ url: URL, recursively: Bool) {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
            chflags(url.path, info.st_flags & ~UInt32(UF_IMMUTABLE))
        }
        guard recursively, let names = try? DirectoryListing.names(in: url) else { return }
        for name in names {
            let child = url.appending(path: name)
            unlock(child, recursively: isFolder(child.path))
        }
    }

    /// Reads back the copy and compares it with the original.
    private func verify(_ source: String, _ target: String) throws {
        guard let a = FileHandle(forReadingAtPath: source), let b = FileHandle(forReadingAtPath: target) else {
            throw TransferError(message: String(localized: "Cannot verify \u{201C}\(target)\u{201D}"))
        }
        defer {
            try? a.close()
            try? b.close()
        }
        while true {
            if progress.isCancelled { throw CancellationError() }
            let chunkA = try a.read(upToCount: 1 << 20) ?? Data()
            let chunkB = try b.read(upToCount: 1 << 20) ?? Data()
            guard chunkA == chunkB else {
                throw TransferError(message: String(localized: "Verification failed: \u{201C}\(target)\u{201D} differs from the original."))
            }
            if chunkA.isEmpty { return }
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
                // Paused, or ahead of the speed limit: copyfile waits here.
                progress.pace(progress.advanceFile(to: bytes))
            }
            return progress.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(progress).toOpaque())

        // COPYFILE_CLONE clones on APFS and falls back to a full copy with metadata.
        // NOFOLLOW: a symbolic link is copied as a link, not as what it points to.
        let flags = options.copiesAttributes ? COPYFILE_CLONE : COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW
        let result = copyfile(source, target, state, copyfile_flags_t(flags))
        let failure = errno
        progress.update {
            // What the callbacks have not counted yet (all of a clone, which has none).
            $0.doneBytes += max(size - $0.fileDoneBytes, 0)
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
