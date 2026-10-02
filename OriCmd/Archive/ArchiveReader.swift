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
    /// Its data needs a password.
    var isEncrypted = false
    /// Its number in lsar's listing (an archive read by The Unarchiver's tools).
    var index: Int?
}

nonisolated struct ArchiveError: LocalizedError {
    enum Kind: Sendable {
        case other
        /// An encrypted entry, and no password given.
        case passwordNeeded
        case wrongPassword
        /// Encrypted, but not as zip archives are: libarchive cannot decrypt it.
        case unsupportedEncryption
    }

    let message: String
    var kind = Kind.other
    var errorDescription: String? { message }

    init(message: String, kind: Kind = .other) {
        self.message = message
        self.kind = kind
    }

    init(_ archive: OpaquePointer?, _ fallback: String) {
        message = archive.flatMap(archive_error_string).map { String(cString: $0) } ?? fallback
    }

    /// The error for an encrypted entry that could not be read with `password`.
    fileprivate static func encrypted(_ url: URL, password: String?, archive: OpaquePointer) -> ArchiveError {
        let name = url.lastPathComponent
        guard ArchiveReader.isZip(archive) else {
            return ArchiveError(message: String(localized:
                "\u{201C}\(name)\u{201D} is encrypted: OriCmd can unpack encrypted zip archives only, not 7z or RAR ones."),
                kind: .unsupportedEncryption)
        }
        return password == nil
            ? ArchiveError(message: String(localized: "\u{201C}\(name)\u{201D} is encrypted: a password is needed."),
                           kind: .passwordNeeded)
            : ArchiveError(message: String(localized: "The password for \u{201C}\(name)\u{201D} is wrong."),
                           kind: .wrongPassword)
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

    /// The entries; a solid RAR 4 archive (which libarchive cannot read) through
    /// The Unarchiver's lsar when it is installed.
    static func entries(of url: URL) throws -> [ArchiveEntry] {
        do {
            return try libarchiveEntries(of: url)
        } catch where Unarchiver.isSolidRAR(error) {
            guard let tools = Unarchiver.tools else { throw Unarchiver.solidError(url) }
            return try Unarchiver.entries(of: url, lsar: tools.lsar)
        }
    }

    private static func libarchiveEntries(of url: URL) throws -> [ArchiveEntry] {
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
                    mode: archive_entry_perm(entry),
                    isEncrypted: archive_entry_is_encrypted(entry) != 0
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
                mode: archive_entry_perm(entry), isSymbolicLink: type == S_IFLNK,
                isEncrypted: archive_entry_is_encrypted(entry) != 0
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

    /// Whether the archive being read is a zip one (libarchive decrypts only those).
    fileprivate static func isZip(_ archive: OpaquePointer) -> Bool {
        archive_format(archive) & 0xFF0000 == 0x50000
    }

    /// Reads the beginning of the first encrypted file with `password`, before
    /// anything is unpacked with it (a file to be replaced would already be cut).
    /// Throws a `.wrongPassword` (or `.unsupportedEncryption`) error.
    @concurrent
    static func check(_ password: String, for url: URL) async throws {
        let archive = try open(url, password: password)
        defer { archive_read_free(archive) }
        var entry: OpaquePointer?
        while archive_read_next_header(archive, &entry) >= ARCHIVE_WARN, let entry {
            guard archive_entry_is_encrypted(entry) != 0, archive_entry_size(entry) > 0 else {
                archive_read_data_skip(archive)
                continue
            }
            var buffer: UnsafeRawPointer?
            var length = 0
            var offset: Int64 = 0
            guard archive_read_data_block(archive, &buffer, &length, &offset) >= ARCHIVE_WARN else {
                throw ArchiveError.encrypted(url, password: password, archive: archive)
            }
            return
        }
    }

    /// Reads every entry's data, so libarchive checks it (the checksums of zip,
    /// 7z, gzip, bzip2, xz); throws for the first entry that is damaged.
    @concurrent
    static func test(_ url: URL, password: String? = nil, progress: TransferProgress) async throws {
        let archive = try open(url, password: password)
        defer { archive_read_free(archive) }
        var entry: OpaquePointer?
        while true {
            if progress.isCancelled { throw CancellationError() }
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { return }
            guard status >= ARCHIVE_WARN, let entry else { throw ArchiveError(archive, url.path) }
            let name = pathname(of: entry)
            let encrypted = archive_entry_is_encrypted(entry) != 0
            if encrypted && (password == nil || !isZip(archive)) {
                throw ArchiveError.encrypted(url, password: nil, archive: archive)
            }
            let size = archive_entry_size(entry)
            progress.update {
                $0.source = url.path + "/" + name
                $0.fileBytes = size
                $0.fileDoneBytes = 0
            }
            var buffer: UnsafeRawPointer?
            var length = 0
            var offset: Int64 = 0
            while true {
                if progress.isCancelled { throw CancellationError() }
                let result = archive_read_data_block(archive, &buffer, &length, &offset)
                if result == ARCHIVE_EOF { break }
                guard result >= ARCHIVE_WARN else {
                    if encrypted { throw ArchiveError.encrypted(url, password: password, archive: archive) }
                    let reason = archive_error_string(archive).map { String(cString: $0) } ?? ""
                    throw ArchiveError(message: String(localized: "\u{201C}\(name)\u{201D} is damaged: \(reason)"))
                }
                let read = Int64(length)
                progress.update {
                    $0.doneBytes += read
                    $0.fileDoneBytes += read
                }
            }
        }
    }

    /// Whether an archive with encrypted entries can be decrypted at all (zip ones).
    @concurrent
    static func decryptsEntries(of url: URL) async -> Bool {
        guard let archive = try? open(url) else { return false }
        defer { archive_read_free(archive) }
        var entry: OpaquePointer?
        return archive_read_next_header(archive, &entry) >= ARCHIVE_WARN && isZip(archive)
    }

    /// Extracts the entries at `paths` (and everything inside them; all entries if
    /// `paths` is empty) into `destination`, removing the `base` folder prefix;
    /// encrypted ones with `password`.
    @concurrent
    static func extract(_ url: URL, paths: [String], base: String, to destination: URL, password: String? = nil,
                        progress: TransferProgress) async throws {
        do {
            try await libarchiveExtract(url, paths: paths, base: base, to: destination, password: password, progress: progress)
        } catch where Unarchiver.isSolidRAR(error) {
            // What was unpacked before libarchive stopped is unpacked again, whole.
            guard let tools = Unarchiver.tools else { throw Unarchiver.solidError(url) }
            try await Unarchiver.extract(url, paths: paths, base: base, to: destination, tools: tools, progress: progress)
        }
    }

    @concurrent
    private static func libarchiveExtract(_ url: URL, paths: [String], base: String, to destination: URL, password: String?,
                                          progress: TransferProgress) async throws {
        let reader = try open(url, password: password)
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
            let encrypted = archive_entry_is_encrypted(entry) != 0
            if encrypted && (password == nil || !isZip(reader)) {
                throw ArchiveError.encrypted(url, password: nil, archive: reader)
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
                guard result >= ARCHIVE_WARN else {
                    throw encrypted ? ArchiveError.encrypted(url, password: password, archive: reader)
                        : ArchiveError(reader, url.path)
                }
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

    private static func open(_ url: URL, password: String? = nil) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw ArchiveError(nil, url.path) }
        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        if let password {
            archive_read_add_passphrase(archive, password)
        }
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
