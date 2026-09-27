import AppKit

enum DirectoryListing {
    /// Reads the entries of `directory` (without "." and "..") using `readdir`/`lstat`,
    /// which is considerably faster than `FileManager` on large directories.
    nonisolated static func items(in directory: URL) throws -> [FileItem] {
        let directoryPath = directory.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        var result: [FileItem] = []
        for name in try names(in: directory) {
            let path = prefix + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }

            let isSymlink = info.st_mode & S_IFMT == S_IFLNK
            var isDirectory = info.st_mode & S_IFMT == S_IFDIR
            if isSymlink {
                var target = stat()
                if stat(path, &target) == 0 {
                    isDirectory = target.st_mode & S_IFMT == S_IFDIR
                }
            }
            let isPackage = isDirectory && name.contains(".")
                && NSWorkspace.shared.isFilePackage(atPath: path)
            let modified = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )

            result.append(FileItem(
                name: name,
                url: URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                isDirectory: isDirectory,
                isPackage: isPackage,
                isSymlink: isSymlink,
                isHidden: name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0,
                size: Int64(info.st_size),
                modified: modified,
                mode: info.st_mode
            ))
        }
        return result
    }

    /// All files below `directory` (not folders, not following symlinked folders),
    /// named by their path relative to it — Total Commander's branch view.
    nonisolated static func branchItems(in directory: URL, includingHidden: Bool, limit: Int = 50_000) -> [FileItem] {
        var result: [FileItem] = []
        func walk(_ folder: URL, prefix: String) {
            guard result.count < limit, let items = try? self.items(in: folder) else { return }
            for item in items where includingHidden || !item.isHidden {
                let path = prefix + item.name
                if item.isFolder && !item.isSymlink {
                    walk(item.url, prefix: path + "/")
                } else if !item.isFolder {
                    result.append(FileItem(name: path, url: item.url, isDirectory: item.isDirectory,
                                           isPackage: item.isPackage, isSymlink: item.isSymlink, isHidden: item.isHidden,
                                           size: item.size, modified: item.modified, mode: item.mode))
                }
            }
        }
        walk(directory, prefix: "")
        return result
    }

    /// Entry names of `directory`, without "." and "..".
    nonisolated static func names(in directory: URL) throws -> [String] {
        guard let stream = opendir(directory.path) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(stream) }

        var names: [String] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }
}
