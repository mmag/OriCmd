import Foundation

enum SortColumn: CaseIterable {
    case name, ext, size, date, attr
}

/// Total Commander ordering: "[..]" first, then folders, then files.
/// Folders are sorted by name unless the panel is sorted by date.
struct SortOrder: Equatable {
    var column: SortColumn = .name
    var ascending = true

    func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted(by: areInIncreasingOrder)
    }

    private func areInIncreasingOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isParent != b.isParent { return a.isParent }
        if a.isFolder != b.isFolder { return a.isFolder }

        let key = a.isFolder && column != .date ? .name : column
        let result = compare(a, b, by: key)
        if result == .orderedSame {
            return compare(a, b, by: .name) == .orderedAscending
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compare(_ a: FileItem, _ b: FileItem, by column: SortColumn) -> ComparisonResult {
        switch column {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .ext:
            return a.fileExtension.localizedStandardCompare(b.fileExtension)
        case .size:
            return a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
        case .date:
            return a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
        case .attr:
            return a.permissions.compare(b.permissions)
        }
    }
}
