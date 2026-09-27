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
    /// ⇧F6 in-place rename was confirmed with Enter.
    func fileList(_ list: FileListView, rename item: FileItem, to newName: String)
    func fileListMarksDidChange(_ list: FileListView)
    func fileListCursorDidMove(_ list: FileListView)
    /// Num+ / Num−: ask for a mask, then mark or unmark matching files.
    func fileList(_ list: FileListView, markGroup mark: Bool)
}

/// Full view file list: one row per entry, a cursor bar that is filled
/// in the active panel and outlined in the inactive one.
final class FileListView: NSView {
    weak var delegate: FileListViewDelegate?

    private(set) var items: [FileItem] = []
    private(set) var cursor = 0
    /// Names of marked entries, drawn in red.
    private(set) var marked: Set<String> = []

    var isActive = false {
        didSet { if isActive != oldValue { needsDisplay = true } }
    }

    private let rowHeight = Theme.rowHeight

    private var renameField: NSTextField?
    private var renamedItem: FileItem?

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

    /// Replaces the entries; marks survive for names that are still present.
    func reload(items: [FileItem], cursor: Int) {
        if let renamedItem, !items.contains(renamedItem) {
            endRenaming()
        }
        self.items = items
        marked.formIntersection(items.map(\.name))
        self.cursor = items.isEmpty ? 0 : min(max(cursor, 0), items.count - 1)
        updateFrameSize()
        needsDisplay = true
        scrollCursorToVisible()
        delegate?.fileListCursorDidMove(self)
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
        delegate?.fileListCursorDidMove(self)
    }

    // MARK: - In-place rename

    /// Shows an editor over the Name and Ext columns of the cursor row,
    /// with the name selected but not the extension.
    func beginRenaming() {
        guard let item = currentItem, !item.isParent else { return }
        endRenaming()
        scrollCursorToVisible()

        let layout = ColumnLayout(width: bounds.width)
        let row = rowRect(cursor)
        let name = layout.rect(for: .name, y: row.minY, height: rowHeight)
        let ext = layout.rect(for: .ext, y: row.minY, height: rowHeight)
        let field = NSTextField(frame: NSRect(x: name.minX + 20, y: row.minY - 1,
                                              width: ext.maxX - name.minX - 20, height: rowHeight + 2))
        field.stringValue = item.name
        field.font = Theme.panelFont
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        addSubview(field)
        renameField = field
        renamedItem = item

        window?.makeFirstResponder(field)
        let length = item.isFolder ? item.name.utf16.count : item.baseName.utf16.count
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
    }

    private func endRenaming(commit: Bool = false) {
        guard let field = renameField, let item = renamedItem else { return }
        renameField = nil
        renamedItem = nil
        let newName = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit {
            delegate?.fileList(self, rename: item, to: newName)
        }
    }

    // MARK: - Marking

    func setMarked(_ names: Set<String>) {
        marked = names
        needsDisplay = true
        delegate?.fileListMarksDidChange(self)
    }

    private func toggleMark(at row: Int) {
        guard items.indices.contains(row), !items[row].isParent else { return }
        let name = items[row].name
        if marked.remove(name) == nil {
            marked.insert(name)
        }
        setNeedsDisplay(rowRect(row))
        delegate?.fileListMarksDidChange(self)
    }

    private func markRange(from start: Int, to end: Int) {
        guard !items.isEmpty else { return }
        let lower = max(min(start, end), 0)
        let upper = min(max(start, end), items.count - 1)
        guard lower <= upper else { return }
        setMarked(marked.union(items[lower...upper].filter { !$0.isParent }.map(\.name)))
    }

    private func toggleMarkAndMove(by offset: Int) {
        toggleMark(at: cursor)
        moveCursor(to: cursor + offset)
    }

    private func markRangeAndMove(to target: Int) {
        markRange(from: cursor, to: target)
        moveCursor(to: target)
    }

    override func selectAll(_ sender: Any?) {
        setMarked(Set(items.filter { !$0.isParent }.map(\.name)))
    }

    @objc(cm_ClearAll:)
    func clearAll(_ sender: Any?) {
        setMarked([])
    }

    /// Inverts the marks of files; marked folders stay marked.
    @objc(cm_ExchangeSelection:)
    func exchangeSelection(_ sender: Any?) {
        let files = Set(items.filter { !$0.isParent && !$0.isFolder }.map(\.name))
        setMarked(marked.subtracting(files).union(files.subtracting(marked)))
    }

    @objc(cm_SpreadSelection:)
    func spreadSelection(_ sender: Any?) {
        delegate?.fileList(self, markGroup: true)
    }

    @objc(cm_ShrinkSelection:)
    func shrinkSelection(_ sender: Any?) {
        delegate?.fileList(self, markGroup: false)
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

        let isMarked = marked.contains(item.name)
        let color = switch (filled, isMarked) {
        case (true, true): Theme.markedCursorText
        case (true, false): Theme.cursorText
        case (false, true): Theme.markedText
        case (false, false): Theme.panelText
        }
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
        if event.modifierFlags.contains(.command) {
            toggleMark(at: row)
            moveCursor(to: row)
            return
        }
        if event.modifierFlags.contains(.shift) {
            markRangeAndMove(to: row)
            return
        }
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
        case (.deleteForward?, []), (.delete?, [.command]):
            tryToPerform(Command.delete.selector, with: self)
        case (.deleteForward?, [.shift]):
            tryToPerform(Command.deletePermanently.selector, with: self)
        case (.insert?, []), (.help?, []):
            toggleMarkAndMove(by: 1)
        case (.upArrow?, [.shift]):
            toggleMarkAndMove(by: -1)
        case (.downArrow?, [.shift]):
            toggleMarkAndMove(by: 1)
        case (.pageUp?, [.shift]):
            markRangeAndMove(to: max(cursor - (visibleRowCount - 1), 0))
        case (.pageDown?, [.shift]):
            markRangeAndMove(to: min(cursor + (visibleRowCount - 1), items.count - 1))
        case (.home?, [.shift]):
            markRangeAndMove(to: 0)
        case (.end?, [.shift]):
            markRangeAndMove(to: items.count - 1)
        case (nil, []), (nil, [.shift]):
            handleCharacter(event)
        default:
            super.keyDown(with: event)
        }
    }

    /// Space marks like Insert; "+", "-", "*" work like the numpad keys in Total Commander.
    private func handleCharacter(_ event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": toggleMarkAndMove(by: 1)
        case "+": spreadSelection(nil)
        case "-": shrinkSelection(nil)
        case "*": exchangeSelection(nil)
        default: super.keyDown(with: event)
        }
    }
}

extension FileListView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRenaming(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRenaming()
            return true
        default:
            return false
        }
    }

    /// Leaving the editor (click elsewhere, Tab) cancels the rename.
    func controlTextDidEndEditing(_ notification: Notification) {
        endRenaming()
    }
}
