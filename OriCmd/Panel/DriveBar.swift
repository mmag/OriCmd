import AppKit

/// Total Commander's drive button bar: a flat button per volume, plus the
/// home folder. The drive holding the panel's folder is highlighted. When the
/// buttons do not fit, they scroll (wheel, trackpad or the arrows at the ends).
final class DriveBar: NSView {
    struct Drive {
        let url: URL
        let title: String
        let icon: NSImage
    }

    static let height: CGFloat = 20

    var drives: [Drive] = [] {
        didSet {
            needsDisplay = true
            revealHighlighted()
        }
    }

    /// The panel's folder; the drive with the longest matching path is highlighted.
    var currentPath = "" {
        didSet {
            if currentPath != oldValue {
                needsDisplay = true
                revealHighlighted()
            }
        }
    }

    /// How far the buttons are scrolled.
    private var offset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private static let arrowWidth: CGFloat = 16

    var onSelect: ((URL) -> Void)?
    /// The context menu of a drive button (as the Finder's for a volume).
    var menuProvider: ((URL) -> NSMenu?)?

    nonisolated override var isFlipped: Bool { true }

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

    private var buttonWidths: [CGFloat] {
        drives.map { min(($0.title as NSString).size(withAttributes: attributes).width + 28, 160) }
    }

    private var contentWidth: CGFloat {
        buttonWidths.reduce(2) { $0 + $1 + 2 }
    }

    private var overflows: Bool { contentWidth > bounds.width }

    /// Where the buttons show: between the arrows when they do not fit.
    private var buttonArea: NSRect {
        overflows ? bounds.insetBy(dx: Self.arrowWidth, dy: 0) : bounds
    }

    private var maxOffset: CGFloat { max(contentWidth - buttonArea.width, 0) }

    private var leftArrow: NSRect { NSRect(x: 0, y: 0, width: Self.arrowWidth, height: bounds.height) }
    private var rightArrow: NSRect {
        NSRect(x: bounds.maxX - Self.arrowWidth, y: 0, width: Self.arrowWidth, height: bounds.height)
    }

    private func buttonRects() -> [NSRect] {
        var x = buttonArea.minX + 2 - offset
        return buttonWidths.map { width in
            defer { x += width + 2 }
            return NSRect(x: x, y: 1, width: width, height: bounds.height - 2)
        }
    }

    /// The button under `point`, if it shows there.
    private func buttonIndex(at point: NSPoint) -> Int? {
        guard buttonArea.contains(point) else { return nil }
        return buttonRects().firstIndex { $0.contains(point) }
    }

    private func scroll(to value: CGFloat) {
        offset = min(max(value, 0), maxOffset)
    }

    /// Scrolls so that the button `index` shows whole.
    private func reveal(_ index: Int) {
        guard bounds.width > 0, buttonRects().indices.contains(index) else { return }
        let rect = buttonRects()[index], area = buttonArea
        if rect.minX < area.minX {
            scroll(to: offset - (area.minX - rect.minX) - 2)
        } else if rect.maxX > area.maxX {
            scroll(to: offset + rect.maxX - area.maxX + 2)
        }
    }

    private func revealHighlighted() {
        scroll(to: offset)
        if let index = highlightedIndex { reveal(index) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        revealHighlighted()
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
        if overflows {
            for (rect, symbol, enabled) in [(leftArrow, "chevron.left", offset > 0),
                                            (rightArrow, "chevron.right", offset < maxOffset)] {
                let color = enabled ? Theme.chromeText : Theme.chromeText.withAlphaComponent(0.3)
                let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) {
                    image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                                          width: image.size.width, height: image.size.height))
                }
            }
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        buttonArea.clip()
        for (index, rect) in buttonRects().enumerated() where rect.intersects(dirtyRect) {
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
        if overflows, leftArrow.contains(point) {
            scroll(to: offset - buttonArea.width * 0.7)
        } else if overflows, rightArrow.contains(point) {
            scroll(to: offset + buttonArea.width * 0.7)
        } else if let index = buttonIndex(at: point) {
            onSelect?(drives[index].url)
        }
    }

    /// The wheel and the trackpad scroll the buttons, sideways or not.
    override func scrollWheel(with event: NSEvent) {
        guard overflows else { return super.scrollWheel(with: event) }
        var delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        scroll(to: offset - delta)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = buttonIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(drives[index].url)
    }

    /// Where the button of the drive at `url` is, scrolled into view (for the tests).
    func buttonRect(for url: URL) -> NSRect? {
        guard let index = drives.firstIndex(where: { $0.url.path == url.path }) else { return nil }
        reveal(index)
        return buttonRects()[index]
    }

    /// Scrolls the buttons by `delta` points (for the tests).
    func scroll(by delta: CGFloat) {
        scroll(to: offset + delta)
    }
}
