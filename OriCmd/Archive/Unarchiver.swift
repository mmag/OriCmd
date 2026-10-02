import Foundation

/// The Unarchiver's command line tools (`lsar`, `unar`; `brew install unar`), used
/// for what the system libarchive cannot read: solid RAR 4 archives. Read-only.
nonisolated enum Unarchiver {
    /// lsar and unar, when installed. A test run looks in `ORICMD_UNAR_DIR` only.
    static var tools: (lsar: String, unar: String)? {
        var folders = ["/opt/homebrew/bin", "/usr/local/bin"]
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["ORICMD_UNAR_DIR"] {
            folders = folder.isEmpty ? [] : [folder]
        }
        #endif
        for folder in folders {
            let (lsar, unar) = (folder + "/lsar", folder + "/unar")
            if FileManager.default.isExecutableFile(atPath: lsar), FileManager.default.isExecutableFile(atPath: unar) {
                return (lsar, unar)
            }
        }
        return nil
    }

    /// libarchive's refusal of a solid RAR 4 archive.
    static func isSolidRAR(_ error: Error) -> Bool {
        (error as? ArchiveError)?.message.contains("RAR solid archive support unavailable") == true
    }

    /// Said instead of libarchive's message when the tools are not there.
    static func solidError(_ url: URL) -> ArchiveError {
        ArchiveError(message: String(localized:
            "\u{201C}\(url.lastPathComponent)\u{201D} is a solid RAR 4 archive, which the system libarchive cannot unpack. Install The Unarchiver's command line tools (brew install unar): OriCmd then uses them."))
    }

    /// The entries as lsar lists them (`lsar -j`).
    static func entries(of url: URL, lsar: String) throws -> [ArchiveEntry] {
        let process = Process()
        process.executableURL = URL(filePath: lsar)
        process.arguments = ["-j", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = json["lsarContents"] as? [[String: Any]] else {
            throw ArchiveError(message: String(localized: "lsar cannot list \u{201C}\(url.lastPathComponent)\u{201D}."))
        }
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return contents.compactMap { entry in
            guard let name = entry["XADFileName"] as? String, let path = ArchiveReader.normalize(name), !path.isEmpty else {
                return nil
            }
            let isDirectory = (entry["XADIsDirectory"] as? NSNumber)?.boolValue == true || name.hasSuffix("/")
            return ArchiveEntry(
                path: path, isDirectory: isDirectory, size: (entry["XADFileSize"] as? NSNumber)?.int64Value ?? 0,
                modified: (entry["XADLastModificationDate"] as? String).flatMap(dates.date(from:)) ?? .distantPast,
                mode: mode_t((entry["XADPosixPermissions"] as? NSNumber)?.intValue ?? (isDirectory ? 0o755 : 0o644)),
                index: (entry["XADIndex"] as? NSNumber)?.intValue
            )
        }
    }

    /// The entries at `paths` (all when empty) unpacked by unar into a temporary
    /// folder, then moved into `destination` without the `base` folder prefix.
    static func extract(_ url: URL, paths: [String], base: String, to destination: URL, tools: (lsar: String, unar: String),
                        progress: TransferProgress) async throws {
        let entries = try entries(of: url, lsar: tools.lsar)
            .filter { entry in paths.isEmpty || paths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "OriCmd-unar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try await ProcessRunner.run(
            tools.unar, ["-o", temporary.path, "-f", "-q", "-D", "-i", url.path] + entries.compactMap(\.index).map(String.init),
            progress: progress)
        guard output.status == 0 else {
            throw ArchiveError(message: output.errors.isEmpty ? "unar: \(output.status)" : output.errors)
        }
        let source = base.isEmpty ? temporary : temporary.appending(path: base)
        try merge(source, into: destination)
    }

    /// Moves what `source` holds into `destination`: folders are merged, files replaced.
    private static func merge(_ source: URL, into destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try DirectoryListing.names(in: source) {
            let from = source.appending(path: name)
            let to = destination.appending(path: name)
            var isFolder: ObjCBool = false
            var targetIsFolder: ObjCBool = false
            manager.fileExists(atPath: from.path, isDirectory: &isFolder)
            if manager.fileExists(atPath: to.path, isDirectory: &targetIsFolder) {
                if isFolder.boolValue && targetIsFolder.boolValue {
                    try merge(from, into: to)
                    continue
                }
                try manager.removeItem(at: to)
            }
            try manager.moveItem(at: from, to: to)
        }
    }
}
