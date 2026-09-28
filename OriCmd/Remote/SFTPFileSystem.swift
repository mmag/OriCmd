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

    /// The control sockets live in a private folder (0700, random name): a
    /// predictable path in /tmp could be taken by another user first. $TMPDIR
    /// would be tidier but too long for a socket path.
    private static let controlDirectory: String = {
        var template = Array("/tmp/oricmd-XXXXXX".utf8CString)
        return template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        } ?? FileManager.default.temporaryDirectory.path
    }()

    private var options: [String] {
        var options = ["-o", "ControlPath=\(Self.controlDirectory)/%C", "-o", "StrictHostKeyChecking=accept-new",
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
        try await ensureMaster()
        if startPath.isEmpty {
            let output = try await sftp(["pwd"])
            if let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Remote working directory: ") }) {
                return String(line.dropFirst("Remote working directory: ".count))
            }
            return "/"
        }
        return startPath
    }

    /// The master connection ends after ten idle minutes (and Disconnect in another
    /// panel ends it too): commands start it again first, with the saved password,
    /// instead of letting ssh ask for it on every command.
    private func ensureMaster() async throws {
        // Checked at most every half minute (progress polls run commands every second).
        if let last = masterChecked.withLock({ $0 }), Date().timeIntervalSince(last) < 30 { return }
        try await SerialTasks.shared.run("ssh-master " + displayName) { [self] in
            let check = try await ProcessRunner.run("/usr/bin/ssh", ["-O", "check"] + options + portOption("-p")
                                                    + ["--", destination], environment: environment)
            if check.status != 0 {
                try await startMaster()
            }
            masterChecked.withLock { $0 = Date() }
        }
    }

    private let masterChecked = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// A login shell on the server in `directory`, over the master connection (so
    /// nothing is asked again; without it ssh asks in the terminal itself). /bin/sh
    /// starts it whatever the login shell is (csh, fish), first reporting its process
    /// number in a private escape sequence; `exec` keeps that number for the shell.
    func shellCommand(in directory: String) async throws -> ShellCommand {
        try await ensureMaster()
        let script = "printf \"\\033]\(ShellCommand.shellPIDCode);%s\\007\" \"$$\"; "
            + "cd -- \"$1\" 2>/dev/null; exec \"${SHELL:-/bin/sh}\" -l"
        let command = "exec /bin/sh -c " + UserCommand.quoted(script) + " oricmd " + UserCommand.quoted(directory)
        return ShellCommand(executable: "/usr/bin/ssh",
                            arguments: ["-t"] + options + portOption("-p") + ["--", destination, command])
    }

    /// What runs in the foreground of the terminal whose shell is `pid` on the server:
    /// nil while the shell itself waits for a command, else the program's name.
    /// Throws when the server cannot tell (no `ps` with `tpgid`, no answer in seconds).
    func foregroundProgram(ofShell pid: Int) async throws -> String? {
        let script = "g=$(ps -o tpgid= -p \(pid) | tr -d \" \"); [ -n \"$g\" ] || exit 3; "
            + "[ \"$g\" = \(pid) ] || ps -o comm= -p \"$g\""
        let arguments = options + portOption("-p") + ["--", destination, "exec /bin/sh -c " + UserCommand.quoted(script)]
        let run = Task { [environment] in
            try await ProcessRunner.run("/usr/bin/ssh", arguments, environment: environment)
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(4))
            run.cancel()
        }
        defer { timeout.cancel() }
        let output = try await run.value
        guard output.status == 0 else { throw RemoteError(output.errors) }
        let name = String(decoding: output.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (name as NSString).lastPathComponent
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
            + options + portOption("-p") + ["--", destination]
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
        masterChecked.withLock { $0 = nil }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = ["-O", "exit"] + options + portOption("-p") + ["--", destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Commands

    /// Runs sftp batch commands over the master connection.
    private func sftp(_ commands: [String], progress: TransferProgress? = nil,
                      onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> String {
        try await ensureMaster()
        let output = try await ProcessRunner.run(
            "/usr/bin/sftp", ["-q", "-b", "-"] + options + portOption("-P") + ["--", destination],
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
            var existing = stat()
            let exists = lstat(local.path, &existing) == 0
            if exists, !item.isSymlink, (existing.st_mode & S_IFMT == S_IFDIR) != item.isDirectory {
                throw RemoteError(String(localized:
                    "\u{201C}\(item.name)\u{201D} is a folder on one side and a file on the other."))
            }
            if item.isDirectory {
                folders.append((item, local))
                level.append((remote, local, top))
                return
            }
            if exists, try await !conflicts.replaces(.remote(item), .local(local)) {
                incomplete.insert(top)
                return
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
        let check = try await checkUpload(files, into: path, conflicts: conflicts, progress: progress)
        var commands: [String] = []
        var planned: [PlannedFile] = []
        var folderModes: [(remote: String, mode: Int)] = []
        func add(_ url: URL, remote: String) throws {
            guard !check.kept.contains(url.path) else { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                                           .fileSizeKey])
            let (local, target) = (try Self.quoted(url.path), try Self.quoted(remote))
            if values?.isSymbolicLink == true {
                commands.append("-put -Rp \(local) \(target)")
                planned.append(PlannedFile(source: url.path, target: remote, size: 0))
            } else if values?.isDirectory == true {
                commands.append("-mkdir \(target)")
                planned.append(PlannedFile(source: url.path, target: remote, size: 0))
                // Folders that exist on the server keep their permissions.
                if !check.existingFolders.contains(remote),
                   let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int {
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
        // Kept files leave the selected items holding them incomplete.
        return Set(files.enumerated().filter { !check.incomplete.contains($0.offset) }.map(\.element))
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
        // A change of letter case only is the same entry on a case-insensitive server,
        // where -l (link + unlink) fails: that one goes through the ordinary rename.
        // (The panel has already checked that no other entry has the new name.)
        let (source, target) = (try Self.quoted(path), try Self.quoted(newPath))
        let caseOnly = path != newPath && path.lowercased() == newPath.lowercased()
        _ = try await sftp(["rename \(caseOnly ? "" : "-l ")\(source) \(target)"])
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
            var usesShell = true
            #if DEBUG
            usesShell = ProcessInfo.processInfo.environment["ORICMD_SFTP_NO_SHELL"] == nil
            #endif
            if usesShell {
                let command = "rm -rf -- " + folders.map(UserCommand.quoted).joined(separator: " ")
                try await ensureMaster()
                let output = try await ProcessRunner.run("/usr/bin/ssh",
                                                         options + portOption("-p") + ["--", destination, command],
                                                         environment: environment)
                if output.status == 0 { return }
            }
            // SFTP-only accounts (internal-sftp) have no shell: remove through sftp itself.
            try await deleteRecursively(folders)
        }
    }

    /// Lists the folders level by level, then removes the files and the folders,
    /// the deepest first.
    private func deleteRecursively(_ roots: [String]) async throws {
        var files: [String] = []
        var folders = roots
        var level = roots
        while !level.isEmpty {
            var next: [String] = []
            for (folder, items) in zip(level, try await list(level)) {
                for item in items {
                    let path = RemotePath.join(folder, item.name)
                    if item.isDirectory {
                        folders.append(path)
                        next.append(path)
                    } else {
                        files.append(path)
                    }
                }
            }
            level = next
        }
        var commands = try files.map { "rm " + (try Self.quoted($0)) }
        // A folder's path is longer than its parent's: longest first empties children first.
        commands += try folders.sorted { $0.count > $1.count }.map { "rmdir " + (try Self.quoted($0)) }
        _ = try await sftp(commands)
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
                set answer to button returned of (display dialog promptText buttons {"No", "Yes"} default button "Yes" with title "OriCmd" with icon caution)
                if answer is "Yes" then return "yes"
                return "no"
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
