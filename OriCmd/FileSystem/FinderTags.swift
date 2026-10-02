import AppKit

/// The Finder's tags of files. The Finder keeps them with their colors in an extended
/// attribute ("Czerwony\n6"); a tag written by a name the Finder knows gets its color,
/// any other name none. The names of the color tags depend on the user's language and
/// renaming, so they are found out, not assumed ("Red" on a Polish Mac is a new tag).
enum FinderTags {
    /// The colors as the Finder lists them, red to gray (as label numbers).
    static let colors = [6, 7, 5, 2, 4, 3, 1]

    /// A file's tags with their colors (0: none).
    static func tags(of url: URL) -> [(name: String, color: Int)] {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let data = url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
        guard let data, let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }
        return entries.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }

    /// The Finder's names of the colors: its favorite tags and the standard names, each
    /// tried on a scratch file to see which color it gets.
    static func colorNames() -> [Int: String] {
        let candidates = (UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames") ?? [])
            + NSWorkspace.shared.fileLabels
        let scratch = FileManager.default.temporaryDirectory.appending(path: "OriCmd-tags-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil) else { return [:] }
        defer { try? FileManager.default.removeItem(at: scratch) }
        var names: [Int: String] = [:]
        for name in candidates where !name.isEmpty && !names.values.contains(name) {
            try? (scratch as NSURL).setResourceValue([name], forKey: .tagNamesKey)
            if let color = tags(of: scratch).first?.color, colors.contains(color), names[color] == nil {
                names[color] = name
            }
            if names.count == colors.count { break }
        }
        return names
    }

    static func setTags(_ names: [String], of url: URL) throws {
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }
}
