import Foundation

/// Creates archives with the system `bsdtar`, which picks the format from the
/// archive's suffix (.zip, .tar.gz/.tgz, .tar.bz2, .tar.xz, .7z, .tar, …).
nonisolated enum ArchiveWriter {
    @concurrent
    static func pack(_ names: [String], in directory: URL, to archive: URL, progress: TransferProgress) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-c", "-a", "-f", archive.path, "-C", directory.path, "--"] + names
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()

        while process.isRunning {
            if progress.isCancelled {
                process.terminate()
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: archive)
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try? FileManager.default.removeItem(at: archive)
            throw ArchiveError(message: message.isEmpty ? "bsdtar: \(process.terminationStatus)" : message)
        }
    }
}
