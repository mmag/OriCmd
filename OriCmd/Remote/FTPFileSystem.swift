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

    private func curl(_ arguments: [String], progress: TransferProgress? = nil) async throws -> ProcessRunner.Output {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var options = ["-s", "-S", "-K", "-", "--connect-timeout", "20"]
        if requiresTLS {
            options.append("--ssl-reqd")
        }
        let output = try await ProcessRunner.run(
            "/usr/bin/curl", options + arguments,
            input: "user = \"\(escaped(user)):\(escaped(password))\"\n", progress: progress
        )
        guard output.status == 0 else {
            throw RemoteError(output.errors.isEmpty ? "curl: \(output.status)" : output.errors)
        }
        return output
    }

    /// Runs FTP commands (MKD, DELE, RMD, RNFR/RNTO) after logging in.
    private func quote(_ commands: [String]) async throws {
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

    func download(_ items: [FileItem], from folder: String, to local: URL, progress: TransferProgress) async throws {
        for item in items {
            let path = RemotePath.join(folder, item.name)
            let target = local.appending(path: item.name)
            progress.update {
                $0.source = path
                $0.target = target.path
            }
            if item.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try await download(try await list(path), from: path, to: target, progress: progress)
            } else {
                _ = try await curl(["-o", target.path, url(for: path, directory: false)], progress: progress)
            }
        }
    }

    func upload(_ files: [URL], to path: String, progress: TransferProgress) async throws {
        for file in files {
            progress.update {
                $0.source = file.path
                $0.target = path
            }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let folder = RemotePath.join(path, file.lastPathComponent)
                try? await quote(["MKD \(folder)"])
                let children = try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)
                try await upload(children, to: folder, progress: progress)
            } else {
                _ = try await curl(["--ftp-create-dirs", "-T", file.path, url(for: path, directory: true)],
                                   progress: progress)
            }
        }
    }

    func makeDirectory(_ path: String) async throws {
        try await quote(["MKD \(path)"])
    }

    func rename(_ path: String, to newPath: String) async throws {
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
