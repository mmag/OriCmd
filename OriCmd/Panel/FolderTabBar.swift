import AppKit

/// Folder tabs above a panel's path bar, drawn as flat TC-style tabs.
/// Click selects a tab, double click or a click of the middle button (the mouse wheel)
/// closes it; a tab dragged to another place of the bar, or to the other panel's, goes there.
final class FolderTabBar: NSView, NSDraggingSource {
    /// A tab being dragged: its identifier (tabs are only dragged inside OriCmd).
    static let pasteboardType = NSPasteboard.PasteboardType("ru.themmag.OriCmd.tab")

    private static let maximumTabWidth: CGFloat = 180
    static let height: CGFloat = 20

    var titles: [String] = [] {
        didSet { needsDisplay = true }
    }

    /// The tabs' identifiers, in the order of `titles`.
    var identifiers: [UUID] = []

    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// Right click on a tab.
    var onContextMenu: ((Int) -> NSMenu?)?
    /// A double click on the empty part of the bar: a new tab, as ⌘T.
    var onNewTab: (() -> Void)?
    /// A tab (from this bar or the other panel's) dropped before the tab at the index
    /// (the count: at the end); whether it went there.
    var onDropTab: ((UUID, Int) -> Bool)?

    /// Where a press on a tab started, until it becomes a drag.
    private var pressed: (point: NSPoint, index: Int)?
    /// The tab the middle button was pressed on: it closes when the button is let go
    /// over it (as in browsers), not when the press leaves it.
    private var middlePressed: Int?
    /// Where a dragged tab would go (a line is drawn there).
    private var dropIndex: Int? {
        didSet { if dropIndex != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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
        if let dropIndex {
            let rects = tabRects()
            let x = dropIndex < rects.count ? rects[dropIndex].minX - 1 : (rects.last?.maxX ?? 2) + 1
            NSColor.controlAccentColor.setFill()
            NSRect(x: x - 1, y: 1, width: 2, height: bounds.height - 2).fill()
        }
    }

    /// The tab under the event's location.
    private func tabIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return tabRects().firstIndex { $0.contains(point) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tabIndex(at: event) else { return nil }
        return onContextMenu?(index)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = nil
        guard let index = tabIndex(at: event) else {
            if event.clickCount == 2 { onNewTab?() }
            return
        }
        if event.clickCount == 2 {
            onClose?(index)
        } else {
            pressed = (point, index)
            onSelect?(index)
        }
    }

    /// A tab pressed and moved a few points is dragged.
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = pressed, hypot(point.x - start.point.x, point.y - start.point.y) > 4,
              identifiers.indices.contains(start.index), tabRects().indices.contains(start.index) else { return }
        pressed = nil
        let item = NSPasteboardItem()
        item.setString(identifiers[start.index].uuidString, forType: Self.pasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let rect = tabRects()[start.index]
        dragging.setDraggingFrame(rect, contents: picture(of: rect))
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
    }

    /// The middle button (the mouse wheel pressed) closes a tab; other extra buttons
    /// (back, forward) go on up the responder chain.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middlePressed = tabIndex(at: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        defer { middlePressed = nil }
        guard let index = middlePressed, tabIndex(at: event) == index else { return }
        onClose?(index)
    }

    private func picture(of rect: NSRect) -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // MARK: - Dropping

    /// The gap nearest to `point`: before the tab whose middle is past it.
    private func insertionIndex(at point: NSPoint) -> Int {
        tabRects().firstIndex { point.x < $0.midX } ?? titles.count
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: Self.pasteboardType) != nil else { return [] }
        dropIndex = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropIndex = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let index = dropIndex ?? insertionIndex(at: convert(sender.draggingLocation, from: nil))
        dropIndex = nil
        guard let text = sender.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: text) else { return false }
        return onDropTab?(id, index) ?? false
    }

    /// Drops a tab as if it were dragged there (for the tests).
    func drop(_ id: UUID, at index: Int) -> Bool {
        onDropTab?(id, index) ?? false
    }

    /// The middle of the tab at the index (for the tests).
    func center(ofTab index: Int) -> NSPoint? {
        let rects = tabRects()
        return rects.indices.contains(index) ? NSPoint(x: rects[index].midX, y: rects[index].midY) : nil
    }
}
