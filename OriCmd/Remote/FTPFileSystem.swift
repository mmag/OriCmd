import Foundation

/// FTP through the system's curl: ftp:// (plain), ftps:// (implicit TLS) and
/// ftpes:// (explicit TLS). Listings use MLSD, or LIST where it is missing.
/// The password goes to curl through stdin, never on its command line.
nonisolated final class FTPFileSystem: RemoteFileSystem {
    private let scheme: String
    private let requiresTLS: Bool
    private let host: String
    private let port: Int?
    private let user: String
    private let password: String
    private let startPath: String
    let displayName: String

    init?(url: URL, password: String?) {
        guard let scheme = url.scheme?.lowercased(), ["ftp", "ftps", "ftpes"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        self.scheme = scheme == "ftps" ? "ftps" : "ftp"
        requiresTLS = scheme == "ftpes"
        self.host = host
        port = url.port
        user = url.user(percentEncoded: false) ?? "anonymous"
        self.password = password ?? url.password(percentEncoded: false) ?? (user == "anonymous" ? "oricmd@" : "")
        let path = url.path(percentEncoded: false)
        startPath = path.isEmpty ? "/" : path
        displayName = scheme + "://" + (user == "anonymous" ? "" : user + "@") + host + (port.map { ":\($0)" } ?? "")
    }

    /// Whether logging in needs a password the URL does not have.
    static func needsPassword(_ url: URL) -> Bool {
        let user = url.user(percentEncoded: false) ?? "anonymous"
        return user != "anonymous" && url.password == nil
    }

    // MARK: - curl

    private var hostPart: String {
        (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
    }

    /// "ftp://host/%2F/abs/path/" — %2F makes the path absolute for curl.
    private func url(for path: String, directory: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#")
        let encoded = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        var text = "\(scheme)://\(hostPart)/%2F" + encoded
        if directory && !text.hasSuffix("/") {
            text += "/"
        }
        return text
    }

    private func baseURL(for path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.user = user == "anonymous" ? nil : user
        components.host = host
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url ?? URL(string: "\(scheme)://\(hostPart)/")!
    }

    /// Runs curl logged in; with `onPercent`, curl's progress bar ("###  42.0%")
    /// reports how much of the file is done.
    private func curl(_ arguments: [String], progress: TransferProgress? = nil,
                      onPercent: (@Sendable (Double) -> Void)? = nil) async throws -> ProcessRunner.Output {
        // curl's config syntax: a line break in the password would end the line.
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        }
        var options = [onPercent == nil ? "-s" : "-#", "-S", "-K", "-", "--connect-timeout", "20"]
        if requiresTLS {
            options.append("--ssl-reqd")
        }
        var onErrors: (@Sendable (Data) -> Void)?
        if let onPercent {
            let lines = LineBuffer()
            onErrors = { data in
                let percents = lines.append(data, separators: [0x0A, 0x0D]).compactMap { Self.percent(in: $0) }
                if let percent = percents.last { onPercent(percent) }
            }
        }
        let output = try await ProcessRunner.run(
            "/usr/bin/curl", options + arguments,
            input: "user = \"\(escaped(user)):\(escaped(password))\"\n", progress: progress, onErrors: onErrors
        )
        guard output.status == 0 else {
            let message = output.errors.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                .filter { !$0.isEmpty && Self.percent(in: $0) == nil && !$0.allSatisfy { "#=O-. ".contains($0) } }
                .joined(separator: "\n")
            throw RemoteError(message.isEmpty ? "curl: \(output.status)" : message)
        }
        return output
    }

    /// The percentage at the end of a curl progress bar line.
    private static func percent(in line: String) -> Double? {
        guard let match = line.firstMatch(of: /#*\s*(\d{1,3}(?:\.\d)?)%\s*$/) else { return nil }
        return Double(match.1)
    }

    /// Runs FTP commands (MKD, DELE, RMD, RNFR/RNTO) after logging in.
    private func quote(_ commands: [String]) async throws {
        // A line break in a path would end the FTP command and start another one.
        for command in commands { try checkRemoteName(command) }
        _ = try await curl(commands.flatMap { ["-Q", $0] } + ["--list-only", url(for: "/", directory: true)])
    }

    // MARK: - RemoteFileSystem

    func connect() async throws -> String {
        _ = try await list(startPath)
        return startPath
    }

    func disconnect() {}

    func list(_ path: String) async throws -> [FileItem] {
        let base = baseURL(for: path)
        if let output = try? await curl(["-X", "MLSD", url(for: path, directory: true)]) {
            let items = Self.parseMLSD(output.text, baseURL: base)
            if !items.isEmpty || output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return items
            }
        }
        let output = try await curl([url(for: path, directory: true)])
        return LongListing.items(from: output.text, baseURL: base)
    }

    /// Lists the folders first (so the progress knows the total), then fetches file by file.
    func download(_ items: [FileItem], from folder: String, to local: URL, progress: TransferProgress,
                  conflicts: RemoteConflicts) async throws -> Set<String> {
        var folders: [URL] = []
        var files: [PlannedFile] = []
        var incomplete = Set<String>()
        func plan(_ items: [FileItem], from folder: String, to local: URL, top: String?) async throws {
            for item in items {
                if progress.isCancelled { throw CancellationError() }
                let path = RemotePath.join(folder, item.name)
                let target = local.appending(path: item.name)
                let top = top ?? item.name
                var existing = stat()
                let exists = lstat(target.path, &existing) == 0
                if exists, !item.isSymlink, (existing.st_mode & S_IFMT == S_IFDIR) != item.isDirectory {
                    throw RemoteError(String(localized:
                        "\u{201C}\(item.name)\u{201D} is a folder on one side and a file on the other."))
                }
                if item.isDirectory {
                    folders.append(target)
                    try await plan(try await list(path), from: path, to: target, top: top)
                    continue
                }
                let answer = exists ? try await conflicts.decide(.remote(item), .local(target)) : .replace
                if answer == .skip {
                    incomplete.insert(top)
                    continue
                }
                files.append(PlannedFile(source: path, target: target.path, size: item.size, resumes: answer == .resume))
            }
        }
        try await plan(items, from: folder, to: local, top: nil)
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let meter = TransferMeter(files: files, progress: progress)
        for (index, file) in files.enumerated() {
            meter.start(index)
            // -C -: curl asks for the rest of the file only (REST), appending it.
            _ = try await curl((file.resumes ? ["-C", "-"] : []) + ["-R", "-o", file.target,
                                                                    url(for: file.source, directory: false)],
                               progress: progress) {
                meter.advance(index, to: Int64(Double(file.size) * $0 / 100))
            }
        }
        meter.finish()
        return Set(items.map(\.name)).subtracting(incomplete)
    }

    /// Creates the folders first, then sends file by file.
    func upload(_ files: [URL], to path: String, progress: TransferProgress,
                conflicts: RemoteConflicts) async throws -> Set<URL> {
        let check = try await checkUpload(files, into: path, conflicts: conflicts, progress: progress)
        var folders: [String] = []
        var planned: [PlannedFile] = []
        func plan(_ url: URL, into path: String) throws {
            guard !check.kept.contains(url.path) else { return }
            try checkRemoteName(url.lastPathComponent)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            let remote = RemotePath.join(path, url.lastPathComponent)
            if values?.isDirectory == true {
                folders.append(remote)
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try plan(child, into: remote)
                }
            } else if values?.isRegularFile == true {
                planned.append(PlannedFile(source: url.path, target: path, size: Int64(values?.fileSize ?? 0),
                                           resumes: check.resumed.contains(url.path)))
            }
        }
        for file in files {
            try plan(file, into: path)
        }
        for folder in folders {
            if progress.isCancelled { throw CancellationError() }
            try? await quote(["MKD \(folder)"])
        }
        let meter = TransferMeter(files: planned, progress: progress)
        for (index, file) in planned.enumerated() {
            meter.start(index)
            // -C -: curl asks the server for the size it has and sends the rest (APPE).
            _ = try await curl((file.resumes ? ["-C", "-"] : []) + ["--ftp-create-dirs", "-T", file.source,
                                                                    url(for: file.target, directory: true)],
                               progress: progress) {
                meter.advance(index, to: Int64(Double(file.size) * $0 / 100))
            }
        }
        meter.finish()
        return Set(files.enumerated().filter { !check.incomplete.contains($0.offset) }.map(\.element))
    }

    func makeDirectory(_ path: String) async throws {
        try await quote(["MKD \(path)"])
    }

    /// Many FTP servers replace an existing target on RNTO: the name is checked first.
    func rename(_ path: String, to newPath: String) async throws {
        let name = (newPath as NSString).lastPathComponent
        if try await list(RemotePath.parent(of: newPath)).contains(where: { $0.name == name }) {
            throw RemoteError(String(localized: "\u{201C}\(name)\u{201D} already exists."))
        }
        try await quote(["RNFR \(path)", "RNTO \(newPath)"])
    }

    func delete(_ items: [FileItem], in folder: String) async throws {
        var commands: [String] = []
        for item in items {
            let path = RemotePath.join(folder, item.name)
            if item.isDirectory {
                try await delete(try await list(path), in: path)
                commands.append("RMD \(path)")
            } else {
                commands.append("DELE \(path)")
            }
        }
        if !commands.isEmpty {
            try await quote(commands)
        }
    }

    /// "type=file;size=12;modify=20240101120000;UNIX.mode=0644; name"
    static func parseMLSD(_ text: String, baseURL: URL) -> [FileItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let parts = fact.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { facts[parts[0].lowercased()] = String(parts[1]) }
            }
            let name = String(line[line.index(after: space)...])
            let type = facts["type"]?.lowercased() ?? "file"
            guard type != "cdir", type != "pdir", name != ".", name != ".." else { return nil }
            let isDirectory = type == "dir"
            var modified = Date.distantPast
            if let stamp = facts["modify"]?.prefix(14), stamp.count == 14 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyyMMddHHmmss"
                modified = formatter.date(from: String(stamp)) ?? .distantPast
            }
            let permissions = facts["unix.mode"].flatMap { mode_t($0, radix: 8) } ?? (isDirectory ? 0o755 : 0o644)
            return FileItem(
                name: name,
                url: baseURL.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                isDirectory: isDirectory, isPackage: false, isSymlink: type.contains("link"),
                isHidden: name.hasPrefix("."), size: Int64(facts["size"] ?? "") ?? 0, modified: modified,
                mode: permissions | (isDirectory ? S_IFDIR : S_IFREG)
            )
        }
    }
}
