import Foundation

/// What to do when a file already exists in the target — the list of
/// Total Commander's "Overwrite options" in the F5 dialog, in its order.
nonisolated enum OverwriteMode: Int, CaseIterable, Sendable {
    case ask = 1, overwriteAll, skipAll, overwriteOlder, renameCopied, renameTarget, copyLarger, copySmaller

    var title: String {
        switch self {
        case .ask: String(localized: "1. Ask user")
        case .overwriteAll: String(localized: "2. Overwrite all")
        case .skipAll: String(localized: "3. Skip all")
        case .overwriteOlder: String(localized: "4. Overwrite all older")
        case .renameCopied: String(localized: "5. Auto-rename copied")
        case .renameTarget: String(localized: "6. Auto-rename target files")
        case .copyLarger: String(localized: "7. Copy all larger files (overwrite smaller)")
        case .copySmaller: String(localized: "8. Copy all smaller files (overwrite larger)")
        }
    }
}

/// The settings of one copy or move, from the F5/F6 dialog.
nonisolated struct TransferOptions: Sendable {
    var overwrite = OverwriteMode.ask
    /// "Only files of this type".
    var filter = CopyFilter("")
    /// Renames the copied files, e.g. "*.bak" (nil keeps the names).
    var renameMask: RenameMask?
    /// Compares every copied file with its source.
    var verify = false
    /// Extended attributes (tags, Finder info) and ACLs; without them only data, dates and permissions.
    var copiesAttributes = true
    var skipsUnreadable = false
    /// Locked (read-only) targets are unlocked to be overwritten, and locked sources to be moved.
    var overwritesLocked = false
}

/// Total Commander's "Only files of this type": "*.jpg *.png" copies only
/// those files; after "|" come exclusions ("*.* | *.bak .git/"); names ending
/// in "/" are folders, matched at any depth.
nonisolated struct CopyFilter: Sendable {
    private let includedFiles: [String]
    private let excludedFiles: [String]
    private let includedFolders: [String]
    private let excludedFolders: [String]

    init(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        func split(_ text: String?) -> (files: [String], folders: [String]) {
            let patterns = (text ?? "").split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init)
            let folders = patterns.filter { $0.hasSuffix("/") || $0.hasSuffix("\\") }.map { String($0.dropLast()) }
            let files = patterns.filter { !$0.hasSuffix("/") && !$0.hasSuffix("\\") }
            return (files, folders)
        }
        let included = split(parts.first)
        let excluded = split(parts.count > 1 ? parts[1] : nil)
        includedFiles = included.files.filter { $0 != "*" && $0 != "*.*" }
        includedFolders = included.folders
        excludedFiles = excluded.files
        excludedFolders = excluded.folders
    }

    var isEmpty: Bool {
        includedFiles.isEmpty && excludedFiles.isEmpty && includedFolders.isEmpty && excludedFolders.isEmpty
    }

    /// Whether a file is copied; `insideIncludedFolder` when a folder named in the
    /// filter contains it (everything in such a folder is copied).
    func includesFile(_ name: String, insideIncludedFolder: Bool) -> Bool {
        if FileMask.matchesAny(name, excludedFiles) { return false }
        if insideIncludedFolder { return true }
        if includedFiles.isEmpty { return includedFolders.isEmpty }
        return FileMask.matchesAny(name, includedFiles)
    }

    func excludesFolder(_ name: String) -> Bool {
        FileMask.matchesAny(name, excludedFolders)
    }

    /// A folder whose whole contents are copied.
    func includesFolder(_ name: String) -> Bool {
        FileMask.matchesAny(name, includedFolders)
    }

    var namesFolders: Bool { !includedFolders.isEmpty }
}

/// Renaming by a target mask as in Total Commander: "*.bak" keeps the name and
/// replaces the extension, "new_*.*" adds a prefix, "?" keeps one character.
nonisolated struct RenameMask: Sendable {
    let mask: String

    /// nil for masks that keep every name ("*", "*.*").
    init?(_ mask: String) {
        guard mask != "*", mask != "*.*", mask.contains(where: { $0 == "*" || $0 == "?" }) else { return nil }
        self.mask = mask
    }

    func apply(to name: String) -> String {
        let (maskName, maskExtension) = Self.split(mask)
        let (baseName, fileExtension) = Self.split(name)
        let newName = Self.fill(maskName, with: baseName)
        guard let maskExtension else { return newName }
        let newExtension = Self.fill(maskExtension, with: fileExtension ?? "")
        return newExtension.isEmpty ? newName : newName + "." + newExtension
    }

    private static func split(_ name: String) -> (String, String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// "*" is the whole original, "?" its character at that position.
    private static func fill(_ pattern: String, with original: String) -> String {
        let characters = Array(original)
        var result = ""
        for (index, character) in pattern.enumerated() {
            switch character {
            case "*": result += original
            case "?": if index < characters.count { result.append(characters[index]) }
            default: result.append(character)
            }
        }
        return result
    }
}
