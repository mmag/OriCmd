import Foundation

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
    func download(_ paths: [String], to folder: URL, progress: TransferProgress) async throws
    func upload(_ files: [URL], to path: String, progress: TransferProgress) async throws
    func makeDirectory(_ path: String) async throws
    func delete(_ items: [FileItem], in folder: String) async throws
    func rename(_ path: String, to newPath: String) async throws
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
