import Foundation

/// Total Commander's "directory hotlist": favourite folders shared by both panels.
enum Hotlist {
    private static let key = "DirectoryHotlist"

    static var directories: [String] {
        AppDefaults.store.stringArray(forKey: key) ?? []
    }

    static func set(_ list: [String]) {
        AppDefaults.store.set(list, forKey: key)
    }

    /// Adds `path`, or removes it if it is already listed.
    static func toggle(_ path: String) {
        var list = directories
        if let index = list.firstIndex(of: path) {
            list.remove(at: index)
        } else {
            list.append(path)
        }
        AppDefaults.store.set(list, forKey: key)
    }
}
