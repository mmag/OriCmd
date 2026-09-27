import AppKit
import UniformTypeIdentifiers

/// Small file icons, cached by extension (packages by path).
enum FileIcons {
    private static let size = NSSize(width: 16, height: 16)
    private static var byExtension: [String: NSImage] = [:]
    private static var byPackagePath: [String: NSImage] = [:]

    private static let folder = sized(NSWorkspace.shared.icon(for: .folder))
    private static let parent = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder")
        ?? folder

    static func icon(for item: FileItem) -> NSImage {
        if item.isParent { return parent }
        if item.isFolder { return folder }
        if item.isPackage {
            return cached(&byPackagePath, item.url.path) { NSWorkspace.shared.icon(forFile: item.url.path) }
        }
        let ext = item.fileExtension.lowercased()
        return cached(&byExtension, ext) {
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
    }

    private static func cached(_ cache: inout [String: NSImage], _ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = sized(make())
        cache[key] = image
        return image
    }

    private static func sized(_ image: NSImage) -> NSImage {
        image.size = size
        return image
    }
}
