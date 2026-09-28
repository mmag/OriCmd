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

    /// Whether the existing `target` is replaced by `source`; false skips it.
    func replaces(_ source: URL, _ target: URL, sourceDate: Date?, targetDate: Date?) async throws -> Bool {
        guard let resolve else { return true }
        let isOlder = (targetDate ?? .distantPast) < (sourceDate ?? .distantFuture)
        switch mode.withLock({ $0 }) {
        case .overwriteAll: return true
        case .skipAll: return false
        case .overwriteOlder: return isOlder
        default: break
        }
        switch await resolve(source, target) {
        case .overwrite:
            return true
        case .overwriteAll:
            mode.withLock { $0 = .overwriteAll }
            return true
        case .skip:
            return false
        case .skipAll:
            mode.withLock { $0 = .skipAll }
            return false
        case .overwriteAllOlder:
            mode.withLock { $0 = .overwriteOlder }
            return isOlder
        case .cancel:
            throw CancellationError()
        }
    }
}

extension RemoteFileSystem {
    /// Before an upload: the local files not to send because they exist in `path`
    /// on the server and are to be kept. Only folders that exist on the server are listed.
    func keptOnServer(_ files: [URL], in path: String, conflicts: RemoteConflicts,
                      progress: TransferProgress) async throws -> Set<String> {
        var kept = Set<String>()
        var level: [(locals: [URL], remote: String)] = [(files, path)]
        while !level.isEmpty {
            var next: [(locals: [URL], remote: String)] = []
            for (locals, remote) in level {
                if progress.isCancelled { throw CancellationError() }
                var existing: [String: FileItem] = [:]
                for item in try await list(remote) { existing[item.name] = item }
                for url in locals {
                    guard let item = existing[url.lastPathComponent] else { continue }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                   .contentModificationDateKey])
                    let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
                    if isFolder && item.isDirectory {
                        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                        next.append((children, RemotePath.join(remote, item.name)))
                    } else if isFolder != item.isDirectory {
                        throw RemoteError(String(localized:
                            "\u{201C}\(item.name)\u{201D} is a folder on one side and a file on the other."))
                    } else if try await !conflicts.replaces(url, item.url, sourceDate: values?.contentModificationDate,
                                                            targetDate: item.modified) {
                        kept.insert(url.path)
                    }
                }
            }
            level = next
        }
        return kept
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
