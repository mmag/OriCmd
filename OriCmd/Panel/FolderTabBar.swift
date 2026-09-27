import AppKit

/// Folder tabs above a panel's path bar, drawn as flat TC-style tabs.
/// Click selects a tab, double click closes it.
final class FolderTabBar: NSView {
    private static let maximumTabWidth: CGFloat = 180
    static let height: CGFloat = 20

    var titles: [String] = [] {
        didSet { needsDisplay = true }
    }

    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        return [.font: Theme.chromeFont, .foregroundColor: Theme.chromeText, .paragraphStyle: paragraph]
    }

    private func tabRects() -> [NSRect] {
        var x: CGFloat = 2
        return titles.map { title in
            let width = min((title as NSString).size(withAttributes: attributes).width + 20, Self.maximumTabWidth)
            defer { x += width + 1 }
            return NSRect(x: x, y: 2, width: width, height: bounds.height - 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chromeBackground.setFill()
        bounds.fill()
        for (index, rect) in tabRects().enumerated() {
            let selected = index == selectedIndex
            (selected ? Theme.panelBackground : Theme.inactiveHeaderBackground).setFill()
            rect.fill()
            Theme.separator.setStroke()
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: rect.minX + 0.5, y: rect.maxY))
            outline.line(to: NSPoint(x: rect.minX + 0.5, y: rect.minY + 0.5))
            outline.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.minY + 0.5))
            outline.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.maxY))
            outline.stroke()
            let textHeight = ceil(Theme.chromeFont.ascender - Theme.chromeFont.descender)
            (titles[index] as NSString).draw(
                with: NSRect(x: rect.minX + 6, y: rect.midY - textHeight / 2, width: rect.width - 12, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes
            )
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabRects().firstIndex(where: { $0.contains(point) }) else { return }
        if event.clickCount == 2 {
            onClose?(index)
        } else {
            onSelect?(index)
        }
    }
}
