import AppKit

/// Total Commander's custom columns: the Full view columns saved under a name,
/// chosen for a panel or taken by themselves in folders matching masks. Name is
/// always the first column; the others keep this order.
struct ColumnSet: Equatable {
    var name: String
    /// The columns after Name, in the order of `SortColumn.optional`.
    var columns: [SortColumn]
    /// "~/Pictures*;*/Photos": the set is used in the folders matching one of these.
    var folders: String

    private static let key = "ColumnSets"

    /// The columns of the Default view, as before sets: Ext, Size, Date, the
    /// optional metadata columns chosen, Attr.
    static var standard: [SortColumn] {
        get {
            if let saved = AppDefaults.store.stringArray(forKey: "DefaultColumns") {
                return SortColumn.optional.filter(saved.compactMap(SortColumn.init(rawValue:)).contains)
            }
            return [.ext, .size, .date] + Settings.extraColumns + [.attr]
        }
        set {
            AppDefaults.store.set(SortColumn.optional.filter(newValue.contains).map(\.rawValue), forKey: "DefaultColumns")
            Settings.extraColumns = SortColumn.extras.filter(newValue.contains)
        }
    }

    static var saved: [ColumnSet] {
        get {
            (AppDefaults.store.array(forKey: key) as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                let columns = (entry["columns"] as? [String] ?? []).compactMap(SortColumn.init(rawValue:))
                return ColumnSet(name: name, columns: SortColumn.optional.filter(columns.contains),
                                 folders: entry["folders"] as? String ?? "")
            }
        }
        set {
            AppDefaults.store.set(newValue.map {
                ["name": $0.name, "columns": $0.columns.map(\.rawValue), "folders": $0.folders] as [String: Any]
            }, forKey: key)
            Settings.notifyChange()
        }
    }

    /// The set for `directory`: the first whose folder masks match it, else the
    /// one chosen for the panel (nil or gone: the Default view, named ""). No
    /// directory (a server's folder): the chosen one.
    static func set(for directory: URL?, chosen: String?) -> (name: String, columns: [SortColumn]) {
        let sets = saved
        if let path = directory?.standardizedFileURL.path, let matching = sets.first(where: { $0.matches(path) }) {
            return (matching.name, matching.columns)
        }
        if let chosen, let set = sets.first(where: { $0.name == chosen }) {
            return (set.name, set.columns)
        }
        return ("", standard)
    }

    /// Masks are matched against the whole path, `~` standing for the home folder.
    private func matches(_ path: String) -> Bool {
        folders.split(separator: ";").contains { mask in
            let mask = (mask.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            return !mask.isEmpty && (mask == path || fnmatch(mask, path, 0) == 0)
        }
    }

    /// Changes the columns of the set named `name` ("" the Default view).
    static func setColumns(_ columns: [SortColumn], of name: String) {
        if name.isEmpty {
            standard = columns
            Settings.notifyChange()
        } else if let index = saved.firstIndex(where: { $0.name == name }) {
            saved[index].columns = SortColumn.optional.filter(columns.contains)
        }
    }
}

/// Show → Columns, made anew each time it opens: the Default view, the sets,
/// and the window to change them. The items go to the active panel.
final class ColumnSetsMenu: NSObject, NSMenuDelegate {
    static let shared = ColumnSetsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for name in [""] + ColumnSet.saved.map(\.name) {
            let item = NSMenuItem(title: name.isEmpty ? String(localized: "Default Columns") : name,
                                  action: #selector(FilePanelController.chooseColumnSetFromMenu(_:)), keyEquivalent: "")
            item.representedObject = name
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Column Sets…"),
                                action: #selector(MainViewController.configureColumnSets(_:)), keyEquivalent: ""))
    }
}
