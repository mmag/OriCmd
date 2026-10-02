import Foundation

/// Net → Download from URL: files fetched over http(s) or ftp by the system curl
/// (which follows redirects and knows the proxies set in System Settings), each
/// under a temporary name until it is complete.
nonisolated enum URLDownloader {
    /// The file name a URL gives ("download" when it has none).
    static func fileName(of url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "download" : name
    }

    /// Downloads each URL into `folder` under the name it gives; returns the files.
    @concurrent
    static func download(_ urls: [URL], into folder: URL, progress: TransferProgress) async throws -> [URL] {
        progress.update { $0.totalBytes = Int64(urls.count) * 100 }
        var files: [URL] = []
        for (index, url) in urls.enumerated() {
            let target = folder.appending(path: fileName(of: url))
            let partial = folder.appending(path: ".oricmd-\(UUID().uuidString.prefix(12)).part")
            progress.update {
                $0.source = url.absoluteString
                $0.target = target.path
                $0.fileBytes = 100
                $0.fileDoneBytes = 0
                $0.doneBytes = Int64(index) * 100
            }
            let lines = LineBuffer()
            do {
                let output = try await ProcessRunner.run(
                    "/usr/bin/curl", ["-L", "-f", "-#", "-S", "--connect-timeout", "20", "-o", partial.path, "--",
                                      url.absoluteString],
                    progress: progress,
                    onErrors: { data in
                        let percents = lines.append(data, separators: [0x0A, 0x0D]).compactMap(Self.percent(in:))
                        guard let percent = percents.last else { return }
                        progress.update {
                            $0.fileDoneBytes = Int64(percent)
                            $0.doneBytes = Int64(index) * 100 + Int64(percent)
                        }
                    })
                guard output.status == 0 else {
                    let message = output.errors.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                        .filter { !$0.isEmpty && Self.percent(in: $0) == nil && !$0.allSatisfy { "#=O-. ".contains($0) } }
                        .joined(separator: "\n")
                    throw TransferError(message: url.absoluteString + ": "
                        + (message.isEmpty ? "curl: \(output.status)" : message))
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: partial, to: target)
                files.append(target)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        }
        return files
    }

    /// The percentage at the end of a curl progress bar line ("###  42.0%").
    private static func percent(in line: String) -> Double? {
        guard let match = line.firstMatch(of: /#*\s*(\d{1,3}(?:\.\d)?)%\s*$/) else { return nil }
        return Double(match.1)
    }
}
