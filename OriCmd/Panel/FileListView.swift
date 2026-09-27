import AppKit

@MainActor
protocol FileListViewDelegate: AnyObject {
    func fileListDidBecomeActive(_ list: FileListView)
    /// Enter / double click: enter a folder or open a file.
    func fileList(_ list: FileListView, openItemAt index: Int)
    /// Ctrl+PgDn: enter a folder or a package (e.g. an .app bundle).
    func fileList(_ list: FileListView, enterItemAt index: Int)
    func fileListGoToParent(_ list: FileListView)
    func fileListSwitchPanel(_ list: FileListView)
}

/// Full view file list: one row per entry, a cursor bar that is filled
/// in the active panel and outlined in the inactive one.
final class FileListView: NSView {
    weak var delegate: FileListViewDelegate?

    private(set) var items: [FileItem] = []
    private(set) var cursor = 0

    var isActive = false {
        didSet { if isActive != oldValue { needsDisplay = true } }
    }

    private let rowHeight = Theme.rowHeight

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        delegate?.fileListDidBecomeActive(self)
        return true
    }

    // MARK: - Content

    func reload(items: [FileItem], cursor: Int) {
        self.items = items
        self.cursor = items.isEmpty ? 0 : min(max(cursor, 0), items.count - 1)
        updateFrameSize()
        needsDisplay = true
        scrollCursorToVisible()
    }

    var currentItem: FileItem? {
        items.indices.contains(cursor) ? items[cursor] : nil
    }

    func moveCursor(to index: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(index, 0), items.count - 1)
        guard clamped != cursor else { return }
        setNeedsDisplay(rowRect(cursor))
        cursor = clamped
        setNeedsDisplay(rowRect(cursor))
        scrollCursorToVisible()
    }

    private var visibleRowCount: Int {
        max(Int(visibleRect.height / rowHeight), 1)
    }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
    }

    private func scrollCursorToVisible() {
        guard !items.isEmpty else { return }
        scrollToVisible(rowRect(cursor))
    }

    // MARK: - Sizing

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let superview else { return }
        superview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(superviewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: superview
        )
        updateFrameSize()
    }

    @objc private func superviewFrameDidChange(_ notification: Notification) {
        updateFrameSize()
    }

    private func updateFrameSize() {
        guard let superview else { return }
        let height = max(CGFloat(items.count) * rowHeight, superview.bounds.height)
        let size = NSSize(width: superview.bounds.width, height: height)
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        dirtyRect.fill()
        guard !items.isEmpty else { return }

        let layout = ColumnLayout(width: bounds.width)
        let first = max(Int(dirtyRect.minY / rowHeight), 0)
        let last = min(Int(dirtyRect.maxY / rowHeight), items.count - 1)
        guard first <= last else { return }
        for row in first...last {
            drawRow(row, layout: layout)
        }
    }

    private func drawRow(_ row: Int, layout: ColumnLayout) {
        let item = items[row]
        let rect = rowRect(row)
        let isCursor = row == cursor
        let filled = isCursor && isActive

        if filled {
            Theme.cursorBackground.setFill()
            rect.fill()
        }

        let color = filled ? Theme.cursorText : Theme.panelText
        let y = rect.minY

        let nameRect = layout.rect(for: .name, y: y, height: rowHeight)
        FileIcons.icon(for: item).draw(
            in: NSRect(x: nameRect.minX + 3, y: y + (rowHeight - 16) / 2, width: 16, height: 16),
            from: .zero, operation: .sourceOver, fraction: item.isHidden ? 0.5 : 1,
            respectFlipped: true, hints: nil
        )
        let name = item.isFolder ? "[\(item.baseName)]" : item.baseName
        drawText(name, in: nameRect.divided(atDistance: 20, from: .minXEdge).remainder,
                 font: Theme.panelFont, color: color)

        drawText(item.fileExtension, in: layout.rect(for: .ext, y: y, height: rowHeight),
                 font: Theme.panelFont, color: color)

        let size: String
        if item.isFolder {
            size = "<DIR>"
        } else if item.isPackage {
            size = "<PKG>"
        } else {
            size = item.size.formatted(.number.grouping(.automatic))
        }
        drawText(size, in: layout.rect(for: .size, y: y, height: rowHeight),
                 font: Theme.panelNumberFont, color: color, alignment: .right)

        if !item.isParent {
            drawText(Self.dateFormatter.string(from: item.modified),
                     in: layout.rect(for: .date, y: y, height: rowHeight),
                     font: Theme.panelNumberFont, color: color)
            drawText(item.permissions, in: layout.rect(for: .attr, y: y, height: rowHeight),
                     font: Theme.panelNumberFont, color: color)
        }

        if isCursor && !isActive {
            Theme.inactiveCursorFrame.setStroke()
            let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            frame.setLineDash([1, 1], count: 2, phase: 0)
            frame.stroke()
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(x: rect.minX + 4, y: rect.minY + (rect.height - textHeight) / 2,
                              width: rect.width - 8, height: textHeight)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(point.y / rowHeight)
        guard items.indices.contains(row) else { return }
        moveCursor(to: row)
        if event.clickCount == 2 {
            delegate?.fileList(self, openItemAt: row)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        switch (event.specialKey, modifiers) {
        case (.upArrow?, []):
            moveCursor(to: cursor - 1)
        case (.downArrow?, []):
            moveCursor(to: cursor + 1)
        case (.pageUp?, []):
            moveCursor(to: cursor - (visibleRowCount - 1))
        case (.pageDown?, []):
            moveCursor(to: cursor + (visibleRowCount - 1))
        case (.home?, []):
            moveCursor(to: 0)
        case (.end?, []):
            moveCursor(to: items.count - 1)
        case (.carriageReturn?, []), (.enter?, []), (.downArrow?, [.command]):
            delegate?.fileList(self, openItemAt: cursor)
        case (.pageDown?, [.control]):
            delegate?.fileList(self, enterItemAt: cursor)
        case (.delete?, []), (.upArrow?, [.command]), (.pageUp?, [.control]):
            delegate?.fileListGoToParent(self)
        case (.tab?, []), (.tab?, [.shift]), (.backTab?, _):
            delegate?.fileListSwitchPanel(self)
        default:
            super.keyDown(with: event)
        }
    }
}
