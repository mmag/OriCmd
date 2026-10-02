import CLibArchive
import Foundation

/// An entry of an archive, with a normalized relative path ("dir/file.txt").
nonisolated struct ArchiveEntry: Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let mode: mode_t
    var isSymbolicLink = false
}

nonisolated struct ArchiveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(message: String) {
        self.message = message
    }

    init(_ archive: OpaquePointer?, _ fallback: String) {
        message = archive.flatMap(archive_error_string).map { String(cString: $0) } ?? fallback
    }
}

/// Reads archives (zip, tar.*, 7z, rar, iso, …) with the system libarchive.
nonisolated enum ArchiveReader {
    private static let extensions: Set<String> = [
        "zip", "jar", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "7z", "rar", "iso", "cab", "cpio", "lha", "lzh", "xar",
    ]
    private static let compoundSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma"]

    /// Whether a file name looks like an archive that can be browsed as a folder.
    static func isArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return compoundSuffixes.contains(where: lower.hasSuffix) || extensions.contains((lower as NSString).pathExtension)
    }

    /// The archive's name without its archive suffix ("photos.tar.gz" → "photos").
    static func baseName(of name: String) -> String {
        let lower = name.lowercased()
        if let suffix = compoundSuffixes.first(where: lower.hasSuffix) {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }

    /// "./a//b/" → "a/b"; nil for paths escaping the archive ("..") .
    static func normalize(_ path: String) -> String? {
        let components = path.split(separator: "/").filter { $0 != "." }
        guard !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    static func entries(of url: URL) throws -> [ArchiveEntry] {
        let archive = try open(url)
        defer { archive_read_free(archive) }

        var result: [ArchiveEntry] = []
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw ArchiveError(archive, url.path) }
            let name = pathname(of: entry)
            if let path = normalize(name), !path.isEmpty {
                result.append(ArchiveEntry(
                    path: path,
                    isDirectory: archive_entry_filetype(entry) & S_IFMT == S_IFDIR || name.hasSuffix("/"),
                    size: archive_entry_size(entry),
                    modified: Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))),
                    mode: archive_entry_perm(entry)
                ))
            }
            archive_read_data_skip(archive)
        }
        return result
    }

    /// Goes through the entries in their order. The data of an entry `wantsData`
    /// asks for is unpacked, up to `dataLimit` bytes (a bigger one gets nil, as one
    /// that cannot be unpacked); `visit` returns false to stop.
    static func scan(_ url: URL, dataLimit: Int, wantsData: (ArchiveEntry) -> Bool,
                     visit: (ArchiveEntry, Data?) -> Bool) throws {
        let archive = try open(url)
        defer { archive_read_free(archive) }
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { return }
            guard status >= ARCHIVE_WARN, let entry else { throw ArchiveError(archive, url.path) }
            let name = pathname(of: entry)
            guard let path = normalize(name), !path.isEmpty else {
                archive_read_data_skip(archive)
                continue
            }
            let type = archive_entry_filetype(entry) & S_IFMT
            let item = ArchiveEntry(
                path: path, isDirectory: type == S_IFDIR || name.hasSuffix("/"), size: archive_entry_size(entry),
                modified: Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))),
                mode: archive_entry_perm(entry), isSymbolicLink: type == S_IFLNK
            )
            let data = !item.isDirectory && item.size <= dataLimit && wantsData(item) ? data(of: archive, limit: dataLimit) : nil
            archive_read_data_skip(archive)
            guard visit(item, data) else { return }
        }
    }

    /// The current entry's data; nil if it is bigger than `limit` or cannot be read.
    private static func data(of archive: OpaquePointer, limit: Int) -> Data? {
        var data = Data()
        var buffer: UnsafeRawPointer?
        var length = 0
        var offset: Int64 = 0
        while true {
            let result = archive_read_data_block(archive, &buffer, &length, &offset)
            if result == ARCHIVE_EOF { return data }
            guard result >= ARCHIVE_WARN, data.count + length <= limit else { return nil }
            if let buffer, length > 0 {
                data.append(buffer.assumingMemoryBound(to: UInt8.self), count: length)
            }
        }
    }

    /// Extracts the entries at `paths` (and everything inside them; all entries if
    /// `paths` is empty) into `destination`, removing the `base` folder prefix.
    @concurrent
    static func extract(_ url: URL, paths: [String], base: String, to destination: URL,
                        progress: TransferProgress) async throws {
        let reader = try open(url)
        defer { archive_read_free(reader) }
        guard let writer = archive_write_disk_new() else { throw ArchiveError(nil, destination.path) }
        defer { archive_write_free(writer) }
        // Target paths are built here from normalized entry paths (no ".."), so they
        // are absolute on purpose; libarchive still refuses ".." and writing through
        // symlinks created by the archive itself.
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME
            | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        archive_write_disk_set_standard_lookup(writer)
        // Symlinks in the destination itself (e.g. /var → /private/var) are fine.
        // (URL.resolvingSymlinksInPath() would strip "/private" again.)
        let destination = realpath(destination.path, nil).map { resolved in
            defer { free(resolved) }
            return URL(filePath: String(cString: resolved))
        } ?? destination

        let prefix = base.isEmpty ? "" : base + "/"
        func target(for name: String) -> String? {
            guard let path = normalize(name), path.hasPrefix(prefix), path.count > prefix.count else { return nil }
            guard paths.isEmpty || paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
            return destination.appending(path: String(path.dropFirst(prefix.count))).path
        }

        var entry: OpaquePointer?
        while true {
            if progress.isCancelled { throw CancellationError() }
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw ArchiveError(reader, url.path) }
            guard let targetPath = target(for: pathname(of: entry)) else {
                archive_read_data_skip(reader)
                continue
            }
            archive_entry_set_pathname(entry, targetPath)
            if let link = archive_entry_hardlink(entry) {
                guard let linkTarget = target(for: String(cString: link)) else {
                    archive_read_data_skip(reader)
                    continue
                }
                archive_entry_set_hardlink(entry, linkTarget)
            }
            let size = archive_entry_size(entry)
            progress.update {
                $0.source = url.path
                $0.target = targetPath
                $0.fileBytes = size
                $0.fileDoneBytes = 0
            }
            guard archive_write_header(writer, entry) >= ARCHIVE_WARN else { throw ArchiveError(writer, targetPath) }

            var buffer: UnsafeRawPointer?
            var length = 0
            var offset: Int64 = 0
            while true {
                let result = archive_read_data_block(reader, &buffer, &length, &offset)
                if result == ARCHIVE_EOF { break }
                guard result >= ARCHIVE_WARN else { throw ArchiveError(reader, url.path) }
                guard archive_write_data_block(writer, buffer, length, offset) >= ARCHIVE_WARN else {
                    throw ArchiveError(writer, targetPath)
                }
                let written = Int64(length)
                progress.update {
                    $0.doneBytes += written
                    $0.fileDoneBytes += written
                }
                if progress.isCancelled { throw CancellationError() }
            }
            archive_write_finish_entry(writer)
        }
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw ArchiveError(nil, url.path) }
        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        guard archive_read_open_filename(archive, url.path, 64 * 1024) == ARCHIVE_OK else {
            let error = ArchiveError(archive, url.path)
            archive_read_free(archive)
            throw error
        }
        return archive
    }

    private static func pathname(of entry: OpaquePointer) -> String {
        if let utf8 = archive_entry_pathname_utf8(entry) { return String(cString: utf8) }
        if let raw = archive_entry_pathname(entry) { return String(cString: raw) }
        return ""
    }
}
