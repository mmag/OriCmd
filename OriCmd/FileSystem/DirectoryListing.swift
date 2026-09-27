import AppKit

enum DirectoryListing {
    /// Reads the entries of `directory` (without "." and "..") using `readdir`/`lstat`,
    /// which is considerably faster than `FileManager` on large directories.
    nonisolated static func items(in directory: URL) throws -> [FileItem] {
        let directoryPath = directory.path
        guard let stream = opendir(directoryPath) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(stream) }

        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        var result: [FileItem] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }

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
}
