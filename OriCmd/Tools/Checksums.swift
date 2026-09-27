import CryptoKit
import Foundation
import os

nonisolated enum ChecksumAlgorithm: String, CaseIterable, Sendable {
    case md5, sha1, sha256, sha512

    var title: String {
        switch self {
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha512: "SHA-512"
        }
    }

    /// Recognizes a checksum by its length in hex digits.
    init?(hexLength: Int) {
        switch hexLength {
        case 32: self = .md5
        case 40: self = .sha1
        case 64: self = .sha256
        case 128: self = .sha512
        default: return nil
        }
    }
}

/// Outcome of verifying a checksum file.
nonisolated final class ChecksumVerification: Sendable {
    struct State {
        var passed = 0
        var failed: [String] = []
        var missing: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var snapshot: State { state.withLock { $0 } }

    fileprivate func record(_ path: String, matches: Bool?) {
        state.withLock {
            switch matches {
            case true?: $0.passed += 1
            case false?: $0.failed.append(path)
            case nil: $0.missing.append(path)
            }
        }
    }
}

/// Creates and verifies checksum files ("hash *name" lines, as md5sum/shasum write them).
nonisolated enum Checksums {
    static let fileExtensions: Set<String> = Set(ChecksumAlgorithm.allCases.map(\.rawValue))

    @concurrent
    static func create(for items: [URL], relativeTo base: URL, algorithm: ChecksumAlgorithm, output: URL,
                       progress: TransferProgress) async throws {
        let files = items.flatMap { collectFiles($0, relativeTo: base) }
        let total = files.reduce(Int64(0)) { $0 + TransferEngine.totalSize(of: $1.url) }
        progress.update { $0.totalBytes = total }
        var lines: [String] = []
        for file in files {
            lines.append("\(try hash(file.url, algorithm, progress: progress)) *\(file.path)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    @concurrent
    static func verify(_ checksumFile: URL, into result: ChecksumVerification, progress: TransferProgress) async throws {
        let base = checksumFile.deletingLastPathComponent()
        let entries = try String(contentsOf: checksumFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { parse(String($0)) }
        let total = entries.reduce(Int64(0)) { $0 + TransferEngine.totalSize(of: base.appending(path: $1.path)) }
        progress.update { $0.totalBytes = total }
        for entry in entries {
            let url = base.appending(path: entry.path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let algorithm = ChecksumAlgorithm(hexLength: entry.hash.count) else {
                result.record(entry.path, matches: nil)
                continue
            }
            let actual = try hash(url, algorithm, progress: progress)
            result.record(entry.path, matches: actual.caseInsensitiveCompare(entry.hash) == .orderedSame)
        }
    }

    /// "hash *name", "hash  name" or BSD style "SHA256 (name) = hash".
    private static func parse(_ line: String) -> (hash: String, path: String)? {
        if let match = line.wholeMatch(of: /(?:MD5|SHA1|SHA256|SHA512) \((.+)\) = ([0-9a-fA-F]+)/) {
            return (String(match.2), String(match.1))
        }
        if let match = line.wholeMatch(of: /([0-9a-fA-F]+)\s+\*?(.+)/) {
            return (String(match.1), String(match.2))
        }
        return nil
    }

    private static func collectFiles(_ url: URL, relativeTo base: URL) -> [(url: URL, path: String)] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [] }
        let prefix = base.standardizedFileURL.path + "/"
        let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return info.st_mode & S_IFMT == S_IFREG ? [(url, path)] : []
        }
        let names = ((try? DirectoryListing.names(in: url)) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.flatMap { collectFiles(url.appending(path: $0), relativeTo: base) }
    }

    private static func hash(_ url: URL, _ algorithm: ChecksumAlgorithm, progress: TransferProgress) throws -> String {
        switch algorithm {
        case .md5: try digest(url, Insecure.MD5.self, progress)
        case .sha1: try digest(url, Insecure.SHA1.self, progress)
        case .sha256: try digest(url, SHA256.self, progress)
        case .sha512: try digest(url, SHA512.self, progress)
        }
    }

    private static func digest<H: HashFunction>(_ url: URL, _ type: H.Type, _ progress: TransferProgress) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let path = url.path
        progress.update {
            $0.source = path
            $0.fileBytes = TransferEngine.totalSize(of: url)
            $0.fileDoneBytes = 0
        }
        var hasher = H()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if progress.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
            let count = Int64(chunk.count)
            progress.update {
                $0.doneBytes += count
                $0.fileDoneBytes += count
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
