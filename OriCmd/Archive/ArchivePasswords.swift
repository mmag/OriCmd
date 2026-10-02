import AppKit

/// The passwords of encrypted archives given in this session, kept in memory only.
enum ArchivePasswords {
    private static var known: [String: String] = [:]

    /// The password to unpack `entries` of `archive` with: nil when none of them
    /// is encrypted, the one given before for the archive, or one asked for now
    /// (asked again while it is wrong). Throws `CancellationError` when the user
    /// cancels, an `.unsupportedEncryption` error for encrypted 7z or RAR archives.
    static func password(for archive: URL, entries: [ArchiveEntry], in window: NSWindow?) async throws -> String? {
        guard entries.contains(where: \.isEncrypted) else { return nil }
        let key = archive.standardizedFileURL.path
        if let password = known[key] { return password }
        guard await ArchiveReader.decryptsEntries(of: archive) else {
            throw ArchiveError(message: String(localized:
                "\u{201C}\(archive.lastPathComponent)\u{201D} is encrypted: OriCmd can unpack encrypted zip archives only, not 7z or RAR ones."),
                kind: .unsupportedEncryption)
        }
        guard let window else { throw CancellationError() }
        var message = String(localized: "The archive is encrypted. Enter its password:")
        while true {
            let typed: String? = await withCheckedContinuation { continuation in
                Prompt.password(String(localized: "Password for \u{201C}\(archive.lastPathComponent)\u{201D}"),
                                message: message, okTitle: String(localized: "OK"), in: window, answer: { password in
                    continuation.resume(returning: password)
                })
            }
            guard let password = typed else { throw CancellationError() }
            do {
                try await ArchiveReader.check(password, for: archive)
                known[key] = password
                return password
            } catch let error as ArchiveError where error.kind == .wrongPassword {
                message = String(localized: "The password is wrong. Enter it again:")
            }
        }
    }

    /// Forgets a password that turned out wrong (for some of the entries).
    static func forget(_ archive: URL) {
        known[archive.standardizedFileURL.path] = nil
    }

    /// The entries `paths` stand for in `entries`: those entries and all inside them.
    static func entries(_ entries: [ArchiveEntry], at paths: [String]) -> [ArchiveEntry] {
        paths.isEmpty ? entries : entries.filter { entry in
            paths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
        }
    }
}
