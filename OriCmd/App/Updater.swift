import AppKit

/// Updates from GitHub Releases: the DMG of the latest release is downloaded,
/// its OriCmd.app replaces this one and the app relaunches (no signing
/// certificate or Sparkle needed; files fetched by the app are not quarantined).
enum Updater {
    nonisolated static let repository = "mmag/OriCmd"
    private static let lastCheckKey = "UpdateLastCheck"
    private static let skippedKey = "UpdateSkippedVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    nonisolated struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }

        /// "v0.2" → "0.2".
        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }

        var dmg: URL? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL
        }
    }

    private nonisolated static var feedURL: URL {
        #if DEBUG
        if let feed = ProcessInfo.processInfo.environment["ORICMD_UPDATE_FEED"], let url = URL(string: feed) {
            return url
        }
        #endif
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// After launch: looks for a release at most once a day and speaks up only
    /// when there is a new one that was not skipped.
    static func checkIfDue(window: NSWindow?) {
        guard Settings.checksForUpdates else { return }
        #if DEBUG
        guard !AppDefaults.isTestRun || ProcessInfo.processInfo.environment["ORICMD_UPDATE_FEED"] != nil else { return }
        #endif
        let last = AppDefaults.store.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > checkInterval else { return }
        check(interactive: false, window: window)
    }

    /// "Check for Updates…" (interactive) also reports "up to date" and errors.
    static func check(interactive: Bool, window: NSWindow?) {
        Task {
            do {
                let release = try await latestRelease()
                AppDefaults.store.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                guard let release, isVersion(release.version, newerThan: currentVersion) else {
                    if interactive {
                        Prompt.info(String(localized: "OriCmd is up to date"),
                                    message: String(localized: "Version \(currentVersion) is the newest one."), in: window)
                    }
                    return
                }
                if !interactive, AppDefaults.store.string(forKey: skippedKey) == release.version {
                    return
                }
                offer(release, window: window)
            } catch {
                if interactive {
                    Prompt.error(String(localized: "Cannot check for updates"), error, in: window)
                }
            }
        }
    }

    /// The latest release, or nil when none is published yet.
    @concurrent
    private nonisolated static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Compares dotted versions numerically: 0.10 is newer than 0.9. A letter
    /// suffix marks a pre-release: 0.2b is newer than 0.1 but older than 0.2,
    /// and 0.2b2 is newer than 0.2b.
    nonisolated static func isVersion(_ version: String, newerThan other: String) -> Bool {
        func parse(_ text: String) -> (numbers: [Int], suffix: String) {
            let numeric = text.prefix { $0.isNumber || $0 == "." }
            return (numeric.split(separator: ".").map { Int($0) ?? 0 }, String(text.dropFirst(numeric.count)))
        }
        let (a, b) = (parse(version), parse(other))
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        switch (a.suffix.isEmpty, b.suffix.isEmpty) {
        case (true, true): return false
        case (true, false): return true
        case (false, true): return false
        case (false, false): return a.suffix.compare(b.suffix, options: .numeric) == .orderedDescending
        }
    }

    private static func offer(_ release: Release, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "OriCmd \(release.version) is available")
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 1500 {
            notes = String(notes.prefix(1500)) + "…"
        }
        alert.informativeText = String(localized: "You have version \(currentVersion).")
            + (notes.isEmpty ? "" : "\n\n" + notes)
        let canInstall = release.dmg != nil && canReplaceApp
        alert.addButton(withTitle: canInstall ? String(localized: "Install and Relaunch") : String(localized: "Open Release Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                if canInstall, let dmg = release.dmg, let window {
                    install(release.version, from: dmg, window: window)
                } else {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            case .alertThirdButtonReturn:
                AppDefaults.store.set(release.version, forKey: skippedKey)
            default:
                break
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    // MARK: - Installing

    private static var canReplaceApp: Bool {
        let app = Bundle.main.bundleURL
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// Downloads the DMG, copies its app next to this one, then quits; a small
    /// script swaps the bundles once the app has exited and starts the new one.
    private static func install(_ version: String, from dmg: URL, window: NSWindow) {
        let app = Bundle.main.bundleURL
        let staged = app.deletingLastPathComponent().appending(path: ".OriCmd-\(version)-update.app")
        let controller = TransferController(title: String(localized: "Downloading OriCmd \(version)"),
                                            failureTitle: String(localized: "Update failed"), window: window)
        Task {
            let done = await controller.run(source: dmg.absoluteString, target: app.path) { progress, _ in
                try await prepare(version, from: dmg, staging: staged, progress: progress)
                return [staged]
            }
            guard !done.isEmpty else { return }
            do {
                try relaunch(replacing: app, with: staged)
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                Prompt.error(String(localized: "Update failed"), error, in: window)
            }
        }
    }

    @concurrent
    private nonisolated static func prepare(_ version: String, from dmg: URL, staging staged: URL,
                                            progress: TransferProgress) async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "OriCmd-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let image = work.appending(path: dmg.lastPathComponent)
        try await download(dmg, to: image, progress: progress)

        let mountPoint = work.appending(path: "mount")
        let attach = try await ProcessRunner.run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path,
        ])
        guard attach.status == 0 else { throw UpdateError(attach.errors) }
        defer {
            let detach = Process()
            detach.executableURL = URL(filePath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-quiet", "-force", mountPoint.path]
            try? detach.run()
            detach.waitUntilExit()
        }

        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError(String(localized: "The disk image does not contain OriCmd."))
        }
        guard (info["CFBundleShortVersionString"] as? String).map({ isVersion($0, newerThan: currentVersion) }) == true else {
            throw UpdateError(String(localized: "The disk image contains an older version."))
        }
        let verify = try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        guard verify.status == 0 else { throw UpdateError(verify.errors) }

        try? FileManager.default.removeItem(at: staged)
        let copy = try await ProcessRunner.run("/usr/bin/ditto", [newApp.path, staged.path], progress: progress)
        guard copy.status == 0 else { throw UpdateError(copy.errors) }
    }

    /// Streams `url` into `file`, counting bytes for the progress window.
    private nonisolated static func download(_ url: URL, to file: URL, progress: TransferProgress) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        let total = max(response.expectedContentLength, 0)
        progress.update {
            $0.totalBytes = total
            $0.fileBytes = total
        }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let done = written
                progress.update {
                    $0.doneBytes = done
                    $0.fileDoneBytes = done
                }
                if progress.isCancelled { throw CancellationError() }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    /// Starts a script that waits for this process to exit, swaps the bundles
    /// and opens the new app (and gives up after a minute if the app stays).
    private static func relaunch(replacing app: URL, with staged: URL) throws {
        let old = app.deletingLastPathComponent().appending(path: ".OriCmd-old-\(UUID().uuidString).app")
        let script = FileManager.default.temporaryDirectory.appending(path: "oricmd-update-\(UUID().uuidString).sh")
        var relaunch = "open \"$APP\""
        #if DEBUG
        if ProcessInfo.processInfo.environment["ORICMD_UPDATE_NO_RELAUNCH"] != nil {
            relaunch = ":"
        }
        #endif
        let body = """
            #!/bin/sh
            APP="$1"; NEW="$2"; OLD="$3"; PID="$4"
            for i in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
            if kill -0 "$PID" 2>/dev/null; then rm -rf "$NEW"; rm -f "$0"; exit 1; fi
            if mv "$APP" "$OLD" && mv "$NEW" "$APP"; then rm -rf "$OLD"; else mv "$OLD" "$APP" 2>/dev/null; rm -rf "$NEW"; fi
            \(relaunch)
            rm -f "$0"

            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path, app.path, staged.path, old.path,
                             String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

nonisolated struct UpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
