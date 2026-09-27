import AppKit

/// Total Commander's drive button bar: a flat button per volume, plus the
/// home folder. The drive holding the panel's folder is highlighted.
final class DriveBar: NSView {
    struct Drive {
        let url: URL
        let title: String
        let icon: NSImage
    }

    static let height: CGFloat = 20

    var drives: [Drive] = [] {
        didSet { needsDisplay = true }
    }

    /// The panel's folder; the drive with the longest matching path is highlighted.
    var currentPath = "" {
        didSet { if currentPath != oldValue { needsDisplay = true } }
    }

    var onSelect: ((URL) -> Void)?

    override var isFlipped: Bool { true }

    /// The startup volume, the home folder, then the other mounted volumes.
    static func drives(for volumes: [Volume]) -> [Drive] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let startup = volumes.filter { $0.url.path == "/" }
        let others = volumes.filter { $0.url.path != "/" }
        let homeDrive = Drive(url: home, title: "~", icon: icon(for: home))
        return startup.map(drive) + [homeDrive] + others.map(drive)
    }

    private static func drive(_ volume: Volume) -> Drive {
        Drive(url: volume.url, title: volume.name, icon: icon(for: volume.url))
    }

    /// Icons are looked up once per volume: asking a sleeping network volume
    /// for its icon can take a while.
    private static var icons: [URL: NSImage] = [:]

    private static func icon(for url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Theme.chromeFont, .foregroundColor: Theme.chromeText]
    }

    private func buttonRects() -> [NSRect] {
        var x: CGFloat = 2
        return drives.map { drive in
            let width = min((drive.title as NSString).size(withAttributes: attributes).width + 28, 160)
            defer { x += width + 2 }
            return NSRect(x: x, y: 1, width: width, height: bounds.height - 2)
        }
    }

    private var highlightedIndex: Int? {
        drives.indices
            .filter { index in
                let path = drives[index].url.path
                return currentPath == path || currentPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            }
            .max { drives[$0].url.path.count < drives[$1].url.path.count }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()
        let highlighted = highlightedIndex
        let textHeight = ceil(Theme.chromeFont.ascender - Theme.chromeFont.descender)
        for (index, rect) in buttonRects().enumerated() {
            if index == highlighted {
                Theme.inactiveHeaderBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            let drive = drives[index]
            drive.icon.draw(in: NSRect(x: rect.minX + 4, y: rect.midY - 7, width: 14, height: 14),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (drive.title as NSString).draw(
                with: NSRect(x: rect.minX + 22, y: rect.midY - textHeight / 2, width: rect.width - 24, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = buttonRects().firstIndex(where: { $0.contains(point) }) {
            onSelect?(drives[index].url)
        }
    }
}
