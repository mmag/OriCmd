import Foundation
import os

nonisolated struct RemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        let lines = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        self.message = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// SFTP through the system's ssh and sftp tools. One master connection per
/// server (ControlMaster) is reused by every command, so ~/.ssh/config, keys and
/// the agent work, and a password or passphrase is only asked for once.
nonisolated final class SFTPFileSystem: RemoteFileSystem {
    private let host: String
    private let user: String?
    private let port: Int?
    private let startPath: String
    private let password: String?
    let displayName: String

    init?(url: URL, password: String?) {
        guard url.scheme == "sftp", let host = url.host(), !host.isEmpty else { return nil }
        self.host = host
        user = url.user(percentEncoded: false)
        port = url.port
        startPath = url.path(percentEncoded: false)
        self.password = password
        var name = "sftp://" + (user.map { "\($0)@" } ?? "") + host
        if let port { name += ":\(port)" }
        displayName = name
    }

    private var destination: String {
        user.map { "\($0)@\(host)" } ?? host
    }

    private var options: [String] {
        var options = ["-o", "ControlPath=/tmp/oricmd-%C", "-o", "StrictHostKeyChecking=accept-new",
                       "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=30"]
        #if DEBUG
        if let config = ProcessInfo.processInfo.environment["ORICMD_SSH_CONFIG"] {
            options = ["-F", config] + options
        }
        #endif
        return options
    }

    private func portOption(_ flag: String) -> [String] {
        port.map { [flag, String($0)] } ?? []
    }

    private var environment: [String: String] {
        ["LC_ALL": "C", "SSH_ASKPASS": Askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]
    }

    // MARK: - Connection

    /// Starts the master connection (asking for a password if needed) and
    /// returns the absolute folder to show first.
    func connect() async throws -> String {
        let check = try await ProcessRunner.run("/usr/bin/ssh", ["-O", "check"] + options + portOption("-p") + [destination],
                                                environment: environment)
        if check.status != 0 {
            try await startMaster()
        }
        if startPath.isEmpty {
            let output = try await sftp(["pwd"])
            if let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Remote working directory: ") }) {
                return String(line.dropFirst("Remote working directory: ".count))
            }
            return "/"
        }
        return startPath
    }

    /// `ssh -f -N` authenticates, then leaves a background master holding the
    /// connection; its output must not go to pipes it would keep open.
    @concurrent
    private func startMaster() async throws {
        let manager = FileManager.default
        let errorsFile = manager.temporaryDirectory.appending(path: "oricmd-ssh-\(UUID().uuidString).log")
        manager.createFile(atPath: errorsFile.path, contents: nil)
        defer { try? manager.removeItem(at: errorsFile) }

        var environment = ProcessInfo.processInfo.environment.merging(self.environment) { $1 }
        var passwordFile: URL?
        if let password {
            let file = manager.temporaryDirectory.appending(path: "oricmd-pw-\(UUID().uuidString)")
            manager.createFile(atPath: file.path, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600])
            environment["ORICMD_SSH_PASSWORD_FILE"] = file.path
            passwordFile = file
        }
        defer { passwordFile.map { try? manager.removeItem(at: $0) } }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = ["-f", "-N", "-o", "ControlMaster=auto", "-o", "ControlPersist=600"]
            + options + portOption("-p") + [destination]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errorsFile)
        try process.run()
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errorsFile, encoding: .utf8)) ?? ""
            throw RemoteError(message.isEmpty ? "ssh: \(process.terminationStatus)" : message)
        }
    }

    func disconnect() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = ["-O", "exit"] + options + portOption("-p") + [destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Commands

    /// Runs sftp batch commands over the master connection.
    private func sftp(_ commands: [String], progress: TransferProgress? = nil,
                      onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> String {
        let output = try await ProcessRunner.run(
            "/usr/bin/sftp", ["-q", "-b", "-"] + options + portOption("-P") + [destination],
            input: commands.joined(separator: "\n") + "\n", environment: environment, progress: progress,
            onOutput: onOutput
        )
        guard output.status == 0 else { throw RemoteError(output.errors) }
        return output.text
    }

    /// Quotes a path for sftp's command parser.
    private static func quoted(_ path: String) throws -> String {
        try checkRemoteName(path)
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private var baseURL: URL {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = user
        components.host = host
        components.port = port
        return components.url ?? URL(string: "sftp://\(host)")!
    }

    func list(_ path: String) async throws -> [FileItem] {
        let folder = try Self.quoted(path)
        let text = try await sftp(["cd \(folder)", "ls -lan"])
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("sftp>") }.joined(separator: "\n")
        return LongListing.items(from: lines, baseURL: baseURL.appending(path: path))
    }

    /// Lists several folders in one session: one listing per path, in order.
    private func list(_ paths: [String]) async throws -> [[FileItem]] {
        let folders = try paths.map(Self.quoted)
        let text = try await sftp(folders.flatMap { ["cd \($0)", "ls -lan"] })
        var chunks: [[Substring]] = []
        var collecting = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("sftp>") {
                collecting = line.hasSuffix("ls -lan")
                if collecting { chunks.append([]) }
            } else if collecting {
                chunks[chunks.count - 1].append(line)
            }
        }
        guard chunks.count == paths.count else { throw RemoteError(String(localized: "Unexpected server listing")) }
        return zip(paths, chunks).map { path, lines in
            LongListing.items(from: lines.joined(separator: "\n"), baseURL: baseURL.appending(path: path))
        }
    }

    /// Downloads file by file (folders are listed first, level by level), so
    /// the progress counts bytes; symbolic links are fetched as sftp resolves them.
    func download(_ items: [FileItem], from folder: String, to destination: URL, progress: TransferProgress,
                  conflicts: RemoteConflicts) async throws -> Set<String> {
        var folders: [(item: FileItem, local: URL)] = []
        var files: [PlannedFile] = []
        var commands: [String] = []
        var level: [(remote: String, local: URL, top: String)] = []
        var incomplete = Set<String>()
        /// `top` is the selected entry the item belongs to.
        func add(_ item: FileItem, remote: String, local: URL, top: String) async throws {
            if item.isDirectory {
                folders.append((item, local))
                level.append((remote, local, top))
                return
            }
            var existing = stat()
            if lstat(local.path, &existing) == 0 {
                let localDate = Date(timeIntervalSince1970: TimeInterval(existing.st_mtimespec.tv_sec))
                guard try await conflicts.replaces(item.url, local, sourceDate: item.modified, targetDate: localDate) else {
                    incomplete.insert(top)
                    return
                }
            }
            let command = item.isSymlink ? "-get -Rp" : "get -p"
            let (source, target) = (try Self.quoted(remote), try Self.quoted(local.path))
            commands.append("\(command) \(source) \(target)")
            files.append(PlannedFile(source: remote, target: local.path, size: item.isSymlink ? 0 : item.size))
        }
        for item in items {
            try await add(item, remote: RemotePath.join(folder, item.name), local: destination.appending(path: item.name),
                          top: item.name)
        }
        while !level.isEmpty {
            if progress.isCancelled { throw CancellationError() }
            let current = level
            level = []
            for ((remote, local, top), children) in zip(current, try await list(current.map(\.remote))) {
                for child in children {
                    try await add(child, remote: RemotePath.join(remote, child.name),
                                  local: local.appending(path: child.name), top: top)
                }
            }
        }
        for (_, local) in folders {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        }
        try await transfer(commands, files: files, progress: progress, pollInterval: .milliseconds(250)) { file in
            var info = stat()
            return lstat(file.target, &info) == 0 ? Int64(info.st_size) : nil
        }
        // Folder permissions and dates, as `get -Rp` kept them (innermost first).
        for (item, local) in folders.reversed() {
            try? FileManager.default.setAttributes([.posixPermissions: Int(item.mode & 0o7777),
                                                    .modificationDate: item.modified], ofItemAtPath: local.path)
        }
        return Set(items.map(\.name)).subtracting(incomplete)
    }

    /// Uploads file by file (creating the folders first), so the progress counts bytes.
    func upload(_ files: [URL], to path: String, progress: TransferProgress,
                conflicts: RemoteConflicts) async throws -> Set<URL> {
        let kept = try await keptOnServer(files, in: path, conflicts: conflicts, progress: progress)
        var commands: [String] = []
        var planned: [PlannedFile] = []
        var folderModes: [(remote: String, mode: Int)] = []
        func add(_ url: URL, remote: String) throws {
            guard !kept.contains(url.path) else { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                                           .fileSizeKey])
            let (local, target) = (try Self.quoted(url.path), try Self.quoted(remote))
            if values?.isSymbolicLink == true {
                commands.append("-put -Rp \(local) \(target)")
                planned.append(PlannedFile(source: url.path, target: remote, size: 0))
            } else if values?.isDirectory == true {
                commands.append("-mkdir \(target)")
                planned.append(PlannedFile(source: url.path, target: remote, size: 0))
                if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int {
                    folderModes.append((remote, mode))
                }
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try add(child, remote: RemotePath.join(remote, child.lastPathComponent))
                }
            } else if values?.isRegularFile == true {
                commands.append("put -p \(local) \(target)")
                planned.append(PlannedFile(source: url.path, target: remote, size: Int64(values?.fileSize ?? 0)))
            }
        }
        for file in files {
            try add(file, remote: RemotePath.join(path, file.lastPathComponent))
        }
        // Folder permissions last, as `put -Rp` kept them (a read-only folder is filled first).
        for (remote, mode) in folderModes.reversed() {
            let target = try Self.quoted(remote)
            commands.append("-chmod \(String(mode & 0o7777, radix: 8)) \(target)")
            planned.append(PlannedFile(source: remote, target: remote, size: 0))
        }
        // The server is only asked about big files, once a second.
        try await transfer(commands, files: planned, progress: progress, pollInterval: .seconds(1)) { [weak self] file in
            guard let self, file.size >= 4 << 20 else { return nil }
            guard let target = try? Self.quoted(file.target) else { return nil }
            let text = try? await sftp(["ls -ln \(target)"])
            return text.flatMap { LongListing.items(from: $0, baseURL: baseURL).first?.size }
        }
        // Kept files leave their folders incomplete.
        return Set(files.filter { file in !kept.contains { $0 == file.path || $0.hasPrefix(file.path + "/") } })
    }

    /// Runs one command per planned file in a single sftp session. sftp echoes
    /// each batch command as it starts it, which tells which file is being copied;
    /// `measure` returns how much of it is done.
    private func transfer(_ commands: [String], files: [PlannedFile], progress: TransferProgress,
                          pollInterval: Duration,
                          measure: @escaping @Sendable (PlannedFile) async -> Int64?) async throws {
        let meter = TransferMeter(files: files, progress: progress)
        let lines = LineBuffer()
        let started = OSAllocatedUnfairLock(initialState: 0)
        let onOutput: @Sendable (Data) -> Void = { data in
            let echoes = lines.append(data).filter { $0.hasPrefix("sftp>") }.count
            guard echoes > 0 else { return }
            let index = started.withLock { count in
                count += echoes
                return count - 1
            }
            meter.start(index)
        }
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if let (index, file) = meter.current, let done = await measure(file) {
                    meter.advance(index, to: done)
                }
            }
        }
        defer { poller.cancel() }
        _ = try await sftp(commands, progress: progress, onOutput: onOutput)
        meter.finish()
    }

    func makeDirectory(_ path: String) async throws {
        let folder = try Self.quoted(path)
        _ = try await sftp(["mkdir \(folder)"])
    }

    func rename(_ path: String, to newPath: String) async throws {
        // -l: the plain SFTP rename, which refuses to replace an existing entry
        // (OpenSSH's default posix-rename would silently overwrite it).
        let (source, target) = (try Self.quoted(path), try Self.quoted(newPath))
        _ = try await sftp(["rename -l \(source) \(target)"])
    }

    /// Files through sftp; folders (sftp cannot remove them recursively) with `rm -rf`.
    func delete(_ items: [FileItem], in folder: String) async throws {
        let files = items.filter { !$0.isDirectory }.map { RemotePath.join(folder, $0.name) }
        let folders = items.filter(\.isDirectory).map { RemotePath.join(folder, $0.name) }
        if !files.isEmpty {
            let quotedFiles = try files.map(Self.quoted)
            _ = try await sftp(quotedFiles.map { "rm \($0)" })
        }
        if !folders.isEmpty {
            let command = "rm -rf -- " + folders.map(UserCommand.quoted).joined(separator: " ")
            let output = try await ProcessRunner.run("/usr/bin/ssh", options + portOption("-p") + [destination, command],
                                                     environment: environment)
            guard output.status == 0 else { throw RemoteError(output.errors) }
        }
    }
}

/// The SSH_ASKPASS helper: answers with the saved password (from a private
/// file) or asks in a dialog.
nonisolated enum Askpass {
    static let path: String = {
        let url = FileManager.default.temporaryDirectory.appending(path: "oricmd-askpass.sh")
        let script = """
            #!/bin/sh
            if [ -n "$ORICMD_SSH_PASSWORD_FILE" ] && [ -s "$ORICMD_SSH_PASSWORD_FILE" ]; then
              cat "$ORICMD_SSH_PASSWORD_FILE"; echo; exit 0
            fi
            exec /usr/bin/osascript - "$1" <<'APPLESCRIPT'
            on run argv
              set promptText to item 1 of argv
              if promptText contains "(yes/no" then
                display dialog promptText buttons {"No", "Yes"} default button "Yes" with title "OriCmd" with icon caution
                return "yes"
              end if
              return text returned of (display dialog promptText default answer "" with hidden answer with title "OriCmd")
            end run
            APPLESCRIPT

            """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }()
}
