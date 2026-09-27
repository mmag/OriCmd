import Foundation

/// The settings of Total Commander's Multi-Rename Tool and how they turn an
/// old file name into a new one.
nonisolated struct MultiRenameRule {
    enum CaseMode: Int, CaseIterable {
        case unchanged, lowercase, uppercase, firstLetterUppercase, eachWordUppercase
    }

    var nameMask = "[N]"
    var extensionMask = "[E]"
    var search = ""
    var replacement = ""
    var usesRegularExpression = false
    var isCaseSensitive = false
    var caseMode = CaseMode.unchanged
    var counterStart = 1
    var counterStep = 1
    var counterDigits = 1

    /// The new name of `item`, the `index`-th file in the list.
    func newName(for item: FileItem, at index: Int) throws -> String {
        let counter = counterStart + index * counterStep
        let base = expand(nameMask, item: item, counter: counter)
        let ext = expand(extensionMask, item: item, counter: counter)
        var name = ext.isEmpty ? base : base + "." + ext
        if !search.isEmpty {
            name = try replaceMatches(in: name)
        }
        return applyCase(name)
    }

    // MARK: - Placeholders

    private static let placeholder = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]"#)

    /// Replaces [N], [N2-5], [E], [C], [P], [Y], [M], [D], [h], [m], [s], [YMD], [hms].
    private func expand(_ mask: String, item: FileItem, counter: Int) -> String {
        let nsMask = mask as NSString
        var result = ""
        var position = 0
        for match in Self.placeholder.matches(in: mask, range: NSRange(location: 0, length: nsMask.length)) {
            result += nsMask.substring(with: NSRange(location: position, length: match.range.location - position))
            let token = nsMask.substring(with: match.range(at: 1))
            result += value(of: token, item: item, counter: counter) ?? nsMask.substring(with: match.range)
            position = match.range.location + match.range.length
        }
        return result + nsMask.substring(from: position)
    }

    private func value(of token: String, item: FileItem, counter: Int) -> String? {
        let date = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.modified)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        switch token {
        case "N": return item.baseName
        case "E": return item.fileExtension
        case "C": return String(format: "%0\(max(counterDigits, 1))d", counter)
        case "P": return item.url.deletingLastPathComponent().lastPathComponent
        case "Y": return String(format: "%04d", date.year ?? 0)
        case "M": return two(date.month)
        case "D": return two(date.day)
        case "h": return two(date.hour)
        case "m": return two(date.minute)
        case "s": return two(date.second)
        case "YMD": return String(format: "%04d", date.year ?? 0) + two(date.month) + two(date.day)
        case "hms": return two(date.hour) + two(date.minute) + two(date.second)
        default:
            // [N2-5], [N3-], [N4] (characters, 1-based), and the same for [E].
            guard let kind = token.first, kind == "N" || kind == "E" else { return nil }
            let source = Array(kind == "N" ? item.baseName : item.fileExtension)
            let bounds = token.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
            guard let first = bounds.first.flatMap({ Int($0) }), first >= 1, bounds.count <= 2 else { return nil }
            let last = bounds.count == 2 ? (bounds[1].isEmpty ? source.count : Int(bounds[1]) ?? 0) : first
            guard first <= source.count else { return "" }
            return String(source[(first - 1)..<min(max(last, first), source.count)])
        }
    }

    // MARK: - Search and replace, case

    private func replaceMatches(in name: String) throws -> String {
        if usesRegularExpression {
            let expression = try NSRegularExpression(pattern: search, options: isCaseSensitive ? [] : .caseInsensitive)
            return expression.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: (name as NSString).length),
                                                       withTemplate: replacement)
        }
        return name.replacingOccurrences(of: search, with: replacement,
                                         options: isCaseSensitive ? [] : .caseInsensitive)
    }

    private func applyCase(_ name: String) -> String {
        switch caseMode {
        case .unchanged: name
        case .lowercase: name.lowercased()
        case .uppercase: name.uppercased()
        case .firstLetterUppercase: name.prefix(1).uppercased() + name.dropFirst().lowercased()
        case .eachWordUppercase: name.capitalized
        }
    }
}

/// Renames several files at once, safely: all go to temporary names first, so
/// swaps (a → b, b → a) work; on failure everything done so far is rolled back.
nonisolated enum BatchRename {
    /// Renames each URL to the paired name in the same folder. Returns the pairs
    /// needed to undo: (new URL, original name).
    static func rename(_ pairs: [(url: URL, newName: String)]) throws -> [(url: URL, newName: String)] {
        let changes = pairs.filter { $0.url.lastPathComponent != $0.newName }
        var temporary: [(from: URL, to: URL)] = []
        var final: [(from: URL, to: URL)] = []
        func rollBack() {
            for step in final.reversed() { Darwin.rename(step.to.path, step.from.path) }
            for step in temporary.reversed() { Darwin.rename(step.to.path, step.from.path) }
        }
        let token = UUID().uuidString
        for (index, change) in changes.enumerated() {
            let temp = change.url.deletingLastPathComponent().appending(path: ".oricmd-rename-\(token)-\(index)")
            guard Darwin.rename(change.url.path, temp.path) == 0 else {
                let error = TransferError.posix(change.url.path)
                rollBack()
                throw error
            }
            temporary.append((change.url, temp))
        }
        for (index, change) in changes.enumerated() {
            let temp = temporary[index].to
            let target = change.url.deletingLastPathComponent().appending(path: change.newName)
            var info = stat()
            guard lstat(target.path, &info) != 0, Darwin.rename(temp.path, target.path) == 0 else {
                let error = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
                rollBack()
                throw error
            }
            final.append((temp, target))
        }
        return changes.map { change in
            (change.url.deletingLastPathComponent().appending(path: change.newName), change.url.lastPathComponent)
        }
    }
}
