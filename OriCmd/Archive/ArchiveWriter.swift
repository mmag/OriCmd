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

    /// Packs `names` (in `directory`) into `archive`. The archive is written under a
    /// temporary name next to it and replaces an existing one only when complete.
    @concurrent
    static func pack(_ names: [String], in directory: URL, to archive: URL, progress: TransferProgress) async throws {
        guard let format = formatOptions(for: archive.lastPathComponent) else {
            throw ArchiveError(message: String(localized:
                "Unknown archive type \u{201C}\(archive.lastPathComponent)\u{201D}: use .zip, .tar.gz, .tar.bz2, .tar.xz, .tar or .7z."))
        }
        let partial = archive.deletingLastPathComponent()
            .appending(path: ".\(archive.lastPathComponent).oricmd-\(UUID().uuidString.prefix(8))")
        do {
            let output = try await ProcessRunner.run(
                "/usr/bin/bsdtar", ["-c"] + format + ["-f", partial.path, "-C", directory.path, "--"] + names,
                progress: progress
            )
            guard output.status == 0 else {
                throw ArchiveError(message: output.errors.isEmpty ? "bsdtar: \(output.status)" : output.errors)
            }
            guard Darwin.rename(partial.path, archive.path) == 0 else { throw TransferError.posix(archive.path) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
