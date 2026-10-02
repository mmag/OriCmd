import AppKit
import CoreServices
import ImageIO
import os

/// A value of an optional metadata column, with its own ordering.
nonisolated enum MetadataValue: Sendable {
    case text(String)
    case date(Date)
    case number(Double, display: String)
    case none

    var display: String {
        switch self {
        case .text(let text): text
        case .date(let date): MetadataCache.dateFormatter.string(from: date)
        case .number(_, let display): display
        case .none: ""
        }
    }

    func compare(_ other: MetadataValue) -> ComparisonResult {
        switch (self, other) {
        case (.text(let a), .text(let b)): a.localizedStandardCompare(b)
        case (.date(let a), .date(let b)): a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (.number(let a, _), .number(let b, _)): a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (.none, .none): .orderedSame
        case (.none, _): .orderedAscending
        case (_, .none): .orderedDescending
        default: display.localizedStandardCompare(other.display)
        }
    }
}

/// Values for the optional columns (kind, creation date, image dimensions,
/// media duration, Finder tags), read in the background and cached per file
/// version. Safe to use from any thread.
nonisolated final class MetadataCache: Sendable {
    static let shared = MetadataCache()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private struct Key: Hashable {
        let path: String
        let modified: Date
        let column: SortColumn
    }

    private struct State {
        var values: [Key: MetadataValue] = [:]
        var pending: Set<Key> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private func key(_ item: FileItem, _ column: SortColumn) -> Key {
        Key(path: item.url.path, modified: item.modified, column: column)
    }

    /// The value, reading it now if it is not cached (used for sorting).
    func value(for item: FileItem, column: SortColumn) -> MetadataValue {
        let key = key(item, column)
        if let value = state.withLock({ $0.values[key] }) { return value }
        let value = Self.read(item, column)
        state.withLock {
            if $0.values.count > 50_000 { $0.values.removeAll() }
            $0.values[key] = value
        }
        return value
    }

    /// The cached value, or nil while it is read in the background; `ready`
    /// runs on the main actor once it is available.
    func cachedValue(for item: FileItem, column: SortColumn, ready: @escaping @MainActor @Sendable () -> Void) -> MetadataValue? {
        let key = key(item, column)
        let (cached, isNew) = state.withLock { state -> (MetadataValue?, Bool) in
            if let value = state.values[key] { return (value, false) }
            return (nil, state.pending.insert(key).inserted)
        }
        if let cached { return cached }
        if isNew {
            Task.detached(priority: .utility) {
                let value = Self.read(item, column)
                self.state.withLock {
                    $0.pending.remove(key)
                    $0.values[key] = value
                }
                await ready()
            }
        }
        return nil
    }

    /// Drops the cached values of a column for these files (their tags changed, which
    /// leaves their modification date as it was).
    func forget(_ urls: [URL], column: SortColumn) {
        let paths = Set(urls.map(\.path))
        state.withLock { state in
            state.values = state.values.filter { !($0.key.column == column && paths.contains($0.key.path)) }
        }
    }

    /// Image size from Spotlight, or read from the file itself when it is not indexed.
    private static func pixelSize(of url: URL) -> (Double, Double)? {
        if let metadata = MDItemCreateWithURL(nil, url as CFURL),
           let width = MDItemCopyAttribute(metadata, kMDItemPixelWidth) as? Double,
           let height = MDItemCopyAttribute(metadata, kMDItemPixelHeight) as? Double {
            return (width, height)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return (width, height)
    }

    private static func read(_ item: FileItem, _ column: SortColumn) -> MetadataValue {
        let url = item.url
        switch column {
        case .kind:
            let kind = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
            return kind.map(MetadataValue.text) ?? .none
        case .created:
            let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            return date.map(MetadataValue.date) ?? .none
        case .tags:
            let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            return tags.isEmpty ? .none : .text(tags.joined(separator: ", "))
        case .dimensions:
            guard !item.isFolder, let (width, height) = pixelSize(of: url) else { return .none }
            return .number(width * height, display: "\(Int(width)) × \(Int(height))")
        case .duration:
            guard !item.isFolder, let metadata = MDItemCreateWithURL(nil, url as CFURL),
                  let seconds = MDItemCopyAttribute(metadata, kMDItemDurationSeconds) as? Double else { return .none }
            let total = Int(seconds.rounded())
            let display = total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
            return .number(seconds, display: display)
        default:
            return .none
        }
    }
}
