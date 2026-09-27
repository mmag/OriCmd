import Foundation

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
    private func sftp(_ commands: [String], progress: TransferProgress? = nil) async throws -> String {
        let output = try await ProcessRunner.run(
            "/usr/bin/sftp", ["-q", "-b", "-"] + options + portOption("-P") + [destination],
            input: commands.joined(separator: "\n") + "\n", environment: environment, progress: progress
        )
        guard output.status == 0 else { throw RemoteError(output.errors) }
        return output.text
    }

    /// Quotes a path for sftp's command parser.
    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
        let text = try await sftp(["cd \(Self.quoted(path))", "ls -lan"])
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("sftp>") }.joined(separator: "\n")
        return LongListing.items(from: lines, baseURL: baseURL.appending(path: path))
    }

    func download(_ paths: [String], to folder: URL, progress: TransferProgress) async throws {
        _ = try await sftp(["lcd \(Self.quoted(folder.path))"] + paths.map { "get -Rp \(Self.quoted($0))" },
                           progress: progress)
    }

    func upload(_ files: [URL], to path: String, progress: TransferProgress) async throws {
        _ = try await sftp(["cd \(Self.quoted(path))"] + files.map { "put -Rp \(Self.quoted($0.path))" },
                           progress: progress)
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await sftp(["mkdir \(Self.quoted(path))"])
    }

    func rename(_ path: String, to newPath: String) async throws {
        _ = try await sftp(["rename \(Self.quoted(path)) \(Self.quoted(newPath))"])
    }

    /// Files through sftp; folders (sftp cannot remove them recursively) with `rm -rf`.
    func delete(_ items: [FileItem], in folder: String) async throws {
        let files = items.filter { !$0.isDirectory }.map { RemotePath.join(folder, $0.name) }
        let folders = items.filter(\.isDirectory).map { RemotePath.join(folder, $0.name) }
        if !files.isEmpty {
            _ = try await sftp(files.map { "rm \(Self.quoted($0))" })
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
