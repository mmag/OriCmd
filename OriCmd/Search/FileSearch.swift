import Foundation
import os

/// Recursive file search by mask and, optionally, by contained text.
/// Runs on a background thread; the UI polls `snapshot` for results.
nonisolated final class FileSearch: Sendable {
    struct Query: Sendable {
        let root: URL
        let masks: String
        let text: String
        let caseSensitive: Bool
    }

    struct State {
        var found: [URL] = []
        var scannedCount = 0
        var isCancelled = false
        var isFinished = false
    }

    /// Larger files are not searched for text.
    private static let textSearchLimit = 256 * 1024 * 1024

    let query: Query
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(query: Query) {
        self.query = query
    }

    var snapshot: State { state.withLock { $0 } }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    @concurrent
    func run() async {
        walk(query.root)
        state.withLock { $0.isFinished = true }
    }

    private var isCancelled: Bool { state.withLock { $0.isCancelled } }

    private func walk(_ directory: URL) {
        guard !isCancelled, let names = try? DirectoryListing.names(in: directory) else { return }
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if isCancelled { return }
            let url = directory.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let isFolder = info.st_mode & S_IFMT == S_IFDIR

            // Text is only looked for in regular files (also behind a symbolic link):
            // a FIFO or a device would block or never end.
            var target = stat()
            let isRegular = info.st_mode & S_IFMT == S_IFREG
                || (info.st_mode & S_IFMT == S_IFLNK && stat(url.path, &target) == 0 && target.st_mode & S_IFMT == S_IFREG)
            if FileMask.matches(name, query.masks) && (query.text.isEmpty || (isRegular && contains(url))) {
                state.withLock { $0.found.append(url) }
            }
            state.withLock { $0.scannedCount += 1 }
            if isFolder {
                walk(url)
            }
        }
    }

    private func contains(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count <= Self.textSearchLimit else { return false }
        if query.caseSensitive {
            return data.range(of: Data(query.text.utf8)) != nil
        }
        return String(decoding: data, as: UTF8.self).range(of: query.text, options: .caseInsensitive) != nil
    }
}
