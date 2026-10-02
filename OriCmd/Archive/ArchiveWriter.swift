import CLibArchive
import Foundation

/// Creates archives with the system `bsdtar`. The format is chosen here from
/// the archive's suffix (in any letter case) and passed explicitly: bsdtar's own
/// choice is case-sensitive and falls back to an uncompressed tar.
nonisolated enum ArchiveWriter {
    /// bsdtar options for the archive named `name`, or nil for an unknown type.
    static func formatOptions(for name: String) -> [String]? {
        let name = name.lowercased()
        let suffixes: [(String, [String])] = [
            (".tar.gz", ["-z"]), (".tgz", ["-z"]),
            (".tar.bz2", ["-j"]), (".tbz2", ["-j"]), (".tbz", ["-j"]),
            (".tar.xz", ["-J"]), (".txz", ["-J"]),
            (".tar", []),
            (".zip", ["--format", "zip"]), (".jar", ["--format", "zip"]),
            (".7z", ["--format", "7zip"]),
        ]
        return suffixes.first { name.hasSuffix($0.0) }?.1
    }

    /// The archive suffix of `name` as typed (".tar.gz", ".ZIP"), or nil.
    static func suffix(of name: String) -> String? {
        let lower = name.lowercased()
        let suffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz", ".tar", ".zip", ".jar", ".7z"]
        return suffixes.first { lower.hasSuffix($0) }.map { String(name.suffix($0.count)) }
    }

    /// Zip archives can be encrypted (7z ones only by programs other than libarchive).
    static func isZip(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") || lower.hasSuffix(".jar")
    }

    enum Compression: Int, CaseIterable, Sendable {
        case normal, fastest, best, store
    }

    enum Encryption: Sendable {
        case aes256
        /// The old zip encryption: weak, but every unzip program reads it.
        case zipCrypto

        fileprivate var option: String { self == .aes256 ? "zip:encryption=aes256" : "zip:encryption=zipcrypt" }
    }

    /// libarchive options for the compression of the archive named `name` (as for
    /// `bsdtar --options`); none for "normal" and for plain tar. Gzip and bzip2 have
    /// no "store": the fastest level stands for it.
    static func compressionOptions(for name: String, _ compression: Compression) -> [String] {
        guard compression != .normal else { return [] }
        let lower = name.lowercased()
        let module: String
        var store = compression == .store
        if isZip(lower) {
            module = "zip"
        } else if lower.hasSuffix(".7z") {
            module = "7zip"
        } else if [".tar.gz", ".tgz"].contains(where: lower.hasSuffix) {
            module = "gzip"
            store = false
        } else if [".tar.bz2", ".tbz2", ".tbz"].contains(where: lower.hasSuffix) {
            module = "bzip2"
            store = false
        } else if [".tar.xz", ".txz"].contains(where: lower.hasSuffix) {
            return [compression == .best ? "xz:compression-level=9" : "xz:compression-level=0"]
        } else {
            return []
        }
        if store { return ["\(module):compression=store"] }
        return ["\(module):compression-level=\(compression == .best ? 9 : 1)"]
    }

    /// How the zip archive at `url` is encrypted, by its first entry's header
    /// (method 99 is WinZip's AES); nil when it is not.
    static func encryption(of url: URL) -> Encryption? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 30), header.count == 30,
              header.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { return nil }
        let bytes = [UInt8](header)
        guard bytes[6] & 1 != 0 else { return nil }
        return UInt16(bytes[8]) | UInt16(bytes[9]) << 8 == 99 ? .aes256 : .zipCrypto
    }

    /// Packs `names` (in `directory`) into `archive`. The archive is written under a
    /// temporary name next to it and replaces an existing one only when complete.
    /// With a password (zip archives only) it is written by libarchive itself:
    /// bsdtar asks for passwords on a terminal only.
    @concurrent
    static func pack(_ names: [String], in directory: URL, to archive: URL, compression: Compression = .normal,
                     password: String? = nil, encryption: Encryption = .aes256, progress: TransferProgress) async throws {
        guard let format = formatOptions(for: archive.lastPathComponent) else {
            throw ArchiveError(message: String(localized:
                "Unknown archive type \u{201C}\(archive.lastPathComponent)\u{201D}: use .zip, .tar.gz, .tar.bz2, .tar.xz, .tar or .7z."))
        }
        let options = compressionOptions(for: archive.lastPathComponent, compression)
        let partial = archive.deletingLastPathComponent()
            .appending(path: ".oricmd-\(UUID().uuidString.prefix(12)).part")
        do {
            if let password {
                guard isZip(archive.lastPathComponent) else {
                    throw ArchiveError(message: String(localized: "Only zip archives can be encrypted."))
                }
                try writeEncryptedZip(names, in: directory, to: partial, options: options + [encryption.option],
                                      password: password, progress: progress)
            } else {
                let output = try await ProcessRunner.run(
                    "/usr/bin/bsdtar", ["-c"] + format + options.flatMap { ["--options", $0] }
                        + ["-f", partial.path, "-C", directory.path, "--"] + names,
                    progress: progress
                )
                guard output.status == 0 else {
                    throw ArchiveError(message: output.errors.isEmpty ? "bsdtar: \(output.status)" : output.errors)
                }
            }
            guard Darwin.rename(partial.path, archive.path) == 0 else { throw TransferError.posix(archive.path) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Writes a zip archive of `names` (folders with everything inside) encrypted
    /// with `password`: files, folders and symbolic links, with their dates and
    /// permissions.
    private static func writeEncryptedZip(_ names: [String], in directory: URL, to output: URL, options: [String],
                                          password: String, progress: TransferProgress) throws {
        var items: [(path: String, info: stat)] = []
        func collect(_ path: String) throws {
            var info = stat()
            let url = directory.appending(path: path)
            guard lstat(url.path, &info) == 0 else { throw TransferError.posix(url.path) }
            items.append((path, info))
            if info.st_mode & S_IFMT == S_IFDIR {
                for name in try DirectoryListing.names(in: url).sorted() {
                    try collect(path + "/" + name)
                }
            }
        }
        for name in names {
            try collect(name)
        }
        let total = items.reduce(Int64(0)) { $0 + ($1.info.st_mode & S_IFMT == S_IFREG ? Int64($1.info.st_size) : 0) }
        progress.update { $0.totalBytes = total }

        guard let writer = archive_write_new() else { throw ArchiveError(nil, output.path) }
        defer { archive_write_free(writer) }
        guard archive_write_set_format_zip(writer) == ARCHIVE_OK,
              options.allSatisfy({ archive_write_set_options(writer, $0) == ARCHIVE_OK }),
              archive_write_set_passphrase(writer, password) == ARCHIVE_OK,
              archive_write_open_filename(writer, output.path) == ARCHIVE_OK else {
            throw ArchiveError(writer, output.path)
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for (path, info) in items {
            if progress.isCancelled { throw CancellationError() }
            let source = directory.appending(path: path)
            guard let entry = archive_entry_new() else { throw ArchiveError(writer, path) }
            defer { archive_entry_free(entry) }
            var copy = info
            archive_entry_copy_stat(entry, &copy)
            archive_entry_set_pathname(entry, path)
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) else {
                    throw TransferError.posix(source.path)
                }
                archive_entry_set_symlink(entry, target)
            }
            progress.update {
                $0.source = source.path
                $0.target = output.path
                $0.fileBytes = type == S_IFREG ? Int64(info.st_size) : 0
                $0.fileDoneBytes = 0
            }
            guard archive_write_header(writer, entry) >= ARCHIVE_WARN else { throw ArchiveError(writer, path) }
            guard type == S_IFREG else { continue }
            let descriptor = Darwin.open(source.path, O_RDONLY)
            guard descriptor >= 0 else { throw TransferError.posix(source.path) }
            defer { close(descriptor) }
            while true {
                if progress.isCancelled { throw CancellationError() }
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw TransferError.posix(source.path) }
                if count == 0 { break }
                guard buffer.withUnsafeBytes({ archive_write_data(writer, $0.baseAddress, count) }) == count else {
                    throw ArchiveError(writer, path)
                }
                progress.update {
                    $0.doneBytes += Int64(count)
                    $0.fileDoneBytes += Int64(count)
                }
            }
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw ArchiveError(writer, output.path) }
    }
}
