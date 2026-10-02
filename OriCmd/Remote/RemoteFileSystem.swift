import Foundation
import os

/// A server shown in a panel (SFTP, FTP). Paths are absolute POSIX paths on
/// the server; entries come back as `FileItem`s whose URL carries the server
/// URL (e.g. sftp://user@host/path) and must not be used as local files.
protocol RemoteFileSystem: AnyObject, Sendable {
    /// "sftp://user@host:port" — shown in the path bar.
    var displayName: String { get }
    /// Connects (asking for a password if needed) and returns the absolute
    /// folder to show first.
    func connect() async throws -> String
    func disconnect()
    func list(_ path: String) async throws -> [FileItem]
    /// Downloads entries of `folder` (folders recursively) into the local `destination`,
    /// asking `conflicts` about files that exist there. Returns the names of the
    /// entries transferred completely (nothing inside skipped).
    func download(_ items: [FileItem], from folder: String, to destination: URL, progress: TransferProgress,
                  conflicts: RemoteConflicts) async throws -> Set<String>
    /// Uploads local files and folders into `path`, asking `conflicts` about files
    /// that exist on the server. Returns the files uploaded completely.
    func upload(_ files: [URL], to path: String, progress: TransferProgress,
                conflicts: RemoteConflicts) async throws -> Set<URL>
    func makeDirectory(_ path: String) async throws
    func delete(_ items: [FileItem], in folder: String) async throws
    func rename(_ path: String, to newPath: String) async throws
}

/// Existing files met by a server transfer: the answers of the usual "File
/// already exists" question, remembered for the whole operation ("all" answers).
nonisolated final class RemoteConflicts: Sendable {
    private let resolve: TransferEngine.ConflictHandler?
    private let mode = OSAllocatedUnfairLock(initialState: OverwriteMode.ask)

    /// Without a handler everything is replaced (downloads into a new temporary folder).
    init(_ resolve: TransferEngine.ConflictHandler?) {
        self.resolve = resolve
    }

    enum Answer: Sendable {
        case replace, skip
        /// The existing smaller file is completed (sftp reget/reput, curl -C -).
        case resume
    }

    /// What becomes of the existing `target` met by `source`: replaced, kept, or,
    /// when it is the smaller file, completed (asked about only, never an "all" answer).
    func decide(_ source: ConflictItem, _ target: ConflictItem) async throws -> Answer {
        guard let resolve else { return .replace }
        let isOlder = (target.modified ?? .distantPast) < (source.modified ?? .distantFuture)
        switch mode.withLock({ $0 }) {
        case .overwriteAll: return .replace
        case .skipAll: return .skip
        case .overwriteOlder: return isOlder ? .replace : .skip
        default: break
        }
        var target = target
        if !source.isFolder, !target.isFolder, let have = target.size, let whole = source.size, have > 0, have < whole {
            target.resumable = true
        }
        switch await resolve(source, target) {
        case .overwrite:
            return .replace
        case .overwriteAll:
            mode.withLock { $0 = .overwriteAll }
            return .replace
        case .skip:
            return .skip
        case .skipAll:
            mode.withLock { $0 = .skipAll }
            return .skip
        case .overwriteAllOlder:
            mode.withLock { $0 = .overwriteOlder }
            return isOlder ? .replace : .skip
        case .resume:
            return target.resumable ? .resume : .replace
        case .cancel:
            throw CancellationError()
        }
    }
}

/// What an upload must leave out, found before it starts.
nonisolated struct UploadCheck: Sendable {
    /// Local files not to send (they exist on the server and are kept), as the
    /// traversal of the local folders names them.
    var kept: Set<String> = []
    /// Indices of the selected items that have something kept (moving must keep
    /// them locally).
    var incomplete: Set<Int> = []
    /// Server folders that existed already (their permissions are left alone).
    var existingFolders: Set<String> = []
    /// Local files whose smaller copy on the server is to be completed.
    var resumed: Set<String> = []
}

extension RemoteFileSystem {
    /// Before an upload: the local files not to send because they exist in `path`
    /// on the server and are to be kept. Only folders that exist on the server are
    /// listed; a symbolic link on the server standing for a folder is entered.
    func checkUpload(_ files: [URL], into path: String, conflicts: RemoteConflicts,
                     progress: TransferProgress) async throws -> UploadCheck {
        var check = UploadCheck()
        var level: [(locals: [URL], remote: String, top: Int?)] = [(files, path, nil)]
        while !level.isEmpty {
            var next: [(locals: [URL], remote: String, top: Int?)] = []
            for (locals, remote, top) in level {
                if progress.isCancelled { throw CancellationError() }
                var existing: [String: FileItem] = [:]
                for item in try await list(remote) { existing[item.name] = item }
                for (index, url) in locals.enumerated() {
                    let top = top ?? index
                    guard let item = existing[url.lastPathComponent] else { continue }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                   .contentModificationDateKey])
                    let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
                    let serverPath = RemotePath.join(remote, item.name)
                    if isFolder && (item.isDirectory || item.isSymlink) {
                        // Listing it next tells whether a link leads to a folder (else it fails).
                        check.existingFolders.insert(serverPath)
                        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                        next.append((children, serverPath, top))
                    } else if isFolder != item.isDirectory {
                        throw RemoteError(String(localized:
                            "\u{201C}\(item.name)\u{201D} is a folder on one side and a file on the other."))
                    } else {
                        switch try await conflicts.decide(.local(url), .remote(item)) {
                        case .replace: break
                        case .resume: check.resumed.insert(url.path)
                        case .skip:
                            check.kept.insert(url.path)
                            check.incomplete.insert(top)
                        }
                    }
                }
            }
            level = next
        }
        return check
    }
}

/// Names with line breaks cannot be passed to sftp's batch mode or FTP commands
/// (they would start a new command), so such transfers are refused.
nonisolated func checkRemoteName(_ path: String) throws {
    if path.contains(where: { $0 == "\n" || $0 == "\r" }) {
        throw RemoteError(String(localized: "Names with line breaks cannot be used on servers: \(path.debugDescription)"))
    }
}

nonisolated enum RemotePath {
    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// One file of a server transfer, planned before it starts so that the
/// progress can count bytes.
nonisolated struct PlannedFile: Sendable {
    let source: String
    let target: String
    let size: Int64
    /// Completes a smaller existing target instead of replacing it.
    var resumes = false
}

/// Byte progress of a transfer that a command line tool makes file by file:
/// the tool reports which file it starts, and the size of the current file
/// is measured while it is being copied.
nonisolated final class TransferMeter: Sendable {
    private let files: [PlannedFile]
    /// Bytes of the files before each file.
    private let offsets: [Int64]
    private let progress: TransferProgress
    private let currentIndex = OSAllocatedUnfairLock<Int?>(initialState: nil)

    init(files: [PlannedFile], progress: TransferProgress) {
        self.files = files
        var offsets: [Int64] = []
        var total: Int64 = 0
        for file in files {
            offsets.append(total)
            total += file.size
        }
        self.offsets = offsets
        self.progress = progress
        let totalBytes = total
        progress.update {
            $0.totalBytes = totalBytes
            $0.doneBytes = 0
        }
    }

    var current: (index: Int, file: PlannedFile)? {
        currentIndex.withLock { $0 }.map { ($0, files[$0]) }
    }

    func start(_ index: Int) {
        guard files.indices.contains(index) else { return }
        currentIndex.withLock { $0 = index }
        let file = files[index]
        let offset = offsets[index]
        progress.update {
            $0.source = file.source
            $0.target = file.target
            $0.fileBytes = file.size
            $0.fileDoneBytes = 0
            $0.doneBytes = offset
        }
    }

    /// `bytes` of file `index` are done (ignored once another file started).
    func advance(_ index: Int, to bytes: Int64) {
        guard currentIndex.withLock({ $0 }) == index else { return }
        let done = min(max(bytes, 0), files[index].size)
        let offset = offsets[index]
        progress.update {
            $0.fileDoneBytes = done
            $0.doneBytes = offset + done
        }
    }

    func finish() {
        progress.update {
            $0.doneBytes = $0.totalBytes
            $0.fileDoneBytes = $0.fileBytes
        }
    }
}

/// Splits streamed output into lines.
nonisolated final class LineBuffer: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [UInt8]())

    /// Adds `data` and returns the lines it completes (without line breaks).
    func append(_ data: Data, separators: Set<UInt8> = [0x0A]) -> [String] {
        pending.withLock { pending in
            pending.append(contentsOf: data)
            var lines: [String] = []
            while let end = pending.firstIndex(where: separators.contains) {
                lines.append(String(decoding: pending[..<end], as: UTF8.self))
                pending.removeSubrange(...end)
            }
            return lines
        }
    }
}

/// Parses `ls -l` style lines ("drwxr-xr-x  2 501 20  96 Sep 27 21:45 name"),
/// as printed by the sftp client (with LC_ALL=C) and by most FTP servers.
nonisolated enum LongListing {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func items(from text: String, baseURL: URL) -> [FileItem] {
        text.split(whereSeparator: \.isNewline).compactMap { item(from: String($0), baseURL: baseURL) }
    }

    static func item(from line: String, baseURL: URL) -> FileItem? {
        let pattern = /^([-dlcbps])([-rwxsStT]{9})\S*\s+\S+\s+\S+\s+\S+\s+(\d+)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.+)$/
        guard let match = line.wholeMatch(of: pattern) else { return nil }
        var name = String(match.7)
        let type = match.1
        if type == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        guard name != ".", name != ".." else { return nil }
        let isDirectory = type == "d"
        return FileItem(
            name: name,
            url: baseURL.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            isDirectory: isDirectory,
            isPackage: false,
            isSymlink: type == "l",
            isHidden: name.hasPrefix("."),
            size: Int64(match.3) ?? 0,
            modified: date(month: String(match.4), day: Int(match.5) ?? 1, timeOrYear: String(match.6)),
            mode: mode(String(match.2), isDirectory: isDirectory)
        )
    }

    /// "Sep 27 21:45" is within the last months (so this or last year); "Sep 27  2021" has the year.
    private static func date(month: String, day: Int, timeOrYear: String) -> Date {
        var components = DateComponents()
        components.month = (months.firstIndex(of: month) ?? 0) + 1
        components.day = day
        let calendar = Calendar(identifier: .gregorian)
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            components.hour = Int(parts[0])
            components.minute = Int(parts[1])
            components.year = calendar.component(.year, from: Date())
            if let date = calendar.date(from: components), date > Date().addingTimeInterval(86_400) {
                components.year! -= 1
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return calendar.date(from: components) ?? .distantPast
    }

    private static func mode(_ text: String, isDirectory: Bool) -> mode_t {
        let bits: [mode_t] = [S_IRUSR, S_IWUSR, S_IXUSR, S_IRGRP, S_IWGRP, S_IXGRP, S_IROTH, S_IWOTH, S_IXOTH]
        var mode: mode_t = isDirectory ? S_IFDIR : S_IFREG
        for (character, bit) in zip(text, bits) where character != "-" && character != "S" && character != "T" {
            mode |= bit
        }
        return mode
    }
}
