import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for the Thumbnails view, generated on demand and cached.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private static let limit = 2000

    private var images: [URL: NSImage] = [:]
    private var pending: Set<URL> = []

    /// The cached thumbnail, or nil while it is generated; `ready` runs once it is.
    func thumbnail(for url: URL, size: CGFloat, ready: @escaping @MainActor () -> Void) -> NSImage? {
        if let image = images[url] { return image }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let cgImage = representation?.cgImage
            Task { @MainActor in
                self.pending.remove(url)
                if self.images.count > Self.limit { self.images.removeAll() }
                self.images[url] = cgImage.map { NSImage(cgImage: $0, size: .zero) }
                    ?? NSWorkspace.shared.icon(forFile: url.path)
                ready()
            }
        }
        return nil
    }
}
