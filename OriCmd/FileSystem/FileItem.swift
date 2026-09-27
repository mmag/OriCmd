import Foundation

/// A single entry in a directory listing.
struct FileItem: Hashable, Sendable {
    let name: String
    let url: URL
    /// True for directories and symlinks to directories.
    let isDirectory: Bool
    /// Bundles such as `.app` are directories that behave like files.
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let mode: mode_t

    /// The `[..]` entry that leads to the parent directory.
    static func parent(of directory: URL) -> FileItem {
        FileItem(
            name: "..", url: directory.deletingLastPathComponent(),
            isDirectory: true, isPackage: false, isSymlink: false, isHidden: false,
            size: 0, modified: .distantPast, mode: 0
        )
    }

    var isParent: Bool { name == ".." }

    /// Directories that are opened by entering them (packages are not).
    var isFolder: Bool { isDirectory && !isPackage }

    /// Name without extension, as shown in the Name column.
    var baseName: String {
        guard let dot = extensionDot else { return name }
        return String(name[..<dot])
    }

    /// Extension without the dot, as shown in the Ext column. Folders have none.
    var fileExtension: String {
        guard let dot = extensionDot else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private var extensionDot: String.Index? {
        guard !isFolder, let dot = name.lastIndex(of: "."),
              dot != name.startIndex, name.index(after: dot) != name.endIndex else { return nil }
        return dot
    }

    /// Unix permissions, e.g. "rwxr-xr-x".
    var permissions: String {
        let symbols: [(mode_t, Character)] = [
            (S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
            (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
            (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x"),
        ]
        return String(symbols.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }
}
