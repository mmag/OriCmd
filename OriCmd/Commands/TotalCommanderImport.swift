import AppKit

/// Total Commander's wincmd.ini taken over: the keys ([Shortcuts]), the colors
/// ([Colors]: files by mask, marked files, the cursor) and the directory hotlist
/// entries of this Mac ([DirMenu] with a path from /, ~ or $HOME).
enum TotalCommanderImport {
    struct Summary {
        var keys = 0
        var fileColors = 0
        var panelColors = 0
        var folders = 0
        var skipped = 0
    }

    static func importSettings(from url: URL) throws -> Summary {
        let keys = try KeyBindings.importTotalCommanderShortcuts(from: url)
        var summary = Summary(keys: keys.imported, skipped: keys.skipped.count)
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? ""
        let sections = Self.sections(of: text)
        importColors(sections["colors"] ?? [:], into: &summary)
        importHotlist(sections["dirmenu"] ?? [:], into: &summary)
        return summary
    }

    /// Section names (lowercased) to their keys (lowercased) and values.
    private static func sections(of text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = line.dropFirst().dropLast().lowercased()
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            sections[current, default: [:]][key] = String(line[line.index(after: equals)...])
        }
        return sections
    }

    /// A Windows color: a decimal number 0x00BBGGRR.
    private static func color(_ value: String?) -> NSColor? {
        guard let value, let number = Int(value.trimmingCharacters(in: .whitespaces)), number >= 0,
              number <= 0xFFFFFF else { return nil }
        return NSColor(srgbRed: CGFloat(number & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255,
                       blue: CGFloat((number >> 16) & 0xFF) / 255, alpha: 1)
    }

    /// ColorFilter1=*.zip;*.rar with ColorFilter1Color=…; filters naming search
    /// templates (">Archives") have no mask to take over. The rules replace the
    /// ones of the same masks.
    private static func importColors(_ section: [String: String], into summary: inout Summary) {
        var rules = ColorSettings.rules
        var index = 1
        while let mask = section["colorfilter\(index)"] {
            defer { index += 1 }
            let masks = mask.trimmingCharacters(in: .whitespaces)
            guard !masks.isEmpty, !masks.hasPrefix(">"),
                  let hex = color(section["colorfilter\(index)color"])?.hexString else {
                summary.skipped += 1
                continue
            }
            rules.removeAll { $0.mask == masks }
            rules.append(ColorSettings.Rule(mask: masks, color: hex))
            summary.fileColors += 1
        }
        if summary.fileColors > 0 { ColorSettings.rules = rules }
        if let marked = color(section["markcolor"]) {
            ColorSettings.markedColor = marked
            summary.panelColors += 1
        }
        if let cursor = color(section["cursorcolor"]) {
            ColorSettings.cursorColor = cursor
            summary.panelColors += 1
        }
        if let cursorText = color(section["cursortext"]) {
            ColorSettings.cursorTextColor = cursorText
            summary.panelColors += 1
        }
    }

    /// menu1=Name with cmd1=cd /path: the folders that exist here.
    private static func importHotlist(_ section: [String: String], into summary: inout Summary) {
        var folders = Hotlist.directories
        for (key, value) in section where key.hasPrefix("cmd") {
            let command = value.trimmingCharacters(in: .whitespaces)
            guard command.lowercased().hasPrefix("cd ") else { continue }
            var path = String(command.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            path = path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
            path = (path as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder),
                  isFolder.boolValue else {
                summary.skipped += 1
                continue
            }
            if !folders.contains(path) {
                folders.append(path)
                summary.folders += 1
            }
        }
        if summary.folders > 0 { Hotlist.set(folders) }
    }
}
