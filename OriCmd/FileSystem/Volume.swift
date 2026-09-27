import Foundation

/// A mounted volume, the macOS counterpart of a drive letter.
struct Volume: Hashable {
    let url: URL
    let name: String

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: Set(keys)))?.volumeLocalizedName
            return Volume(url: url, name: name ?? url.lastPathComponent)
        }
    }

    /// The mounted volume that contains `url`.
    static func containing(_ url: URL, in volumes: [Volume]) -> Volume? {
        let path = url.standardizedFileURL.path
        return volumes
            .filter { path == $0.url.path || path.hasPrefix($0.url.path.hasSuffix("/") ? $0.url.path : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }
}

/// Free and total space of the volume holding a URL.
struct VolumeSpace {
    let available: Int64
    let total: Int64

    init?(for url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        guard let values, let total = values.volumeTotalCapacity else { return nil }
        self.available = values.volumeAvailableCapacityForImportantUsage ?? 0
        self.total = Int64(total)
    }

    /// "12 345 678 k of 487 654 321 k free", as Total Commander shows it.
    var summary: String {
        let free = (available / 1024).formatted(.number.grouping(.automatic))
        let all = (total / 1024).formatted(.number.grouping(.automatic))
        return String(localized: "\(free) k of \(all) k free")
    }
}
