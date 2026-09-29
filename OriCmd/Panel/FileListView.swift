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
    /// Lets the command line take typed characters first. Returns true if consumed.
    func fileList(_ list: FileListView, interceptKey event: NSEvent) -> Bool
    /// ⌥/⌃⌥ + letter: starts quick search with `text`.
    func fileList(_ list: FileListView, beginQuickSearchWith text: String)
    /// Space on a folder: its size should be calculated, as in Total Commander.
    func fileList(_ list: FileListView, calculateSizeOf item: FileItem)
    /// Right click: the context menu for the given entries.
    func fileList(_ list: FileListView, contextMenuFor items: [FileItem]) -> NSMenu?
    /// Whether entries may be dragged out (not from inside archives).
    func fileListCanDragItems(_ list: FileListView) -> Bool
    /// Files were dropped on the list, or on the folder entry `folder`.
    func fileList(_ list: FileListView, drop urls: [URL], into folder: FileItem?, moving: Bool) -> Bool
    /// Files promised by the program they are dragged from (Remote Desktop, Mail).
    func fileList(_ list: FileListView, dropPromises receivers: [NSFilePromiseReceiver], into folder: FileItem?) -> Bool
}

/// The file list of a panel, in Full view (one row per entry with details) or
/// Brief view (names only, in columns filled top to bottom). The cursor bar is
/// filled in the active panel and outlined in the inactive one.
final class FileListView: NSView {
    enum ViewMode: String {
        case full, brief, thumbnails
    }

    weak var delegate: FileListViewDelegate?

    var viewMode = ViewMode.full {
        didSet {
            guard viewMode != oldValue else { return }
            updateBriefColumnWidth()
            updateFrameSize()
            needsDisplay = true
            scrollCursorToVisible()
        }
    }

    private var briefColumnWidth: CGFloat = 160

    private(set) var items: [FileItem] = []
    private(set) var cursor = 0
    /// Names of marked entries, drawn in red.
    private(set) var marked: Set<String> = []
    /// Calculated folder sizes by name, shown instead of <DIR>.
    var folderSizes: [String: Int64] = [:] {
        didSet { needsDisplay = true }
    }

    var isActive = false {
        didSet { if isActive != oldValue { needsDisplay = true } }
    }

    private var rowHeight = Theme.rowHeight

    private var renameField: NSTextField?
    private var renamedItem: FileItem?

    /// Where a click started, for telling drags from clicks.
    var dragOrigin: (point: NSPoint, row: Int)?
    /// The folder entry highlighted as drop target.
    var dropTargetRow: Int? {
        didSet { if dropTargetRow != oldValue { needsDisplay = true } }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL] + promiseTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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
        updateBriefColumnWidth()
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

    /// Font or other settings changed: re-measure rows and redraw.
    func settingsDidChange() {
        rowHeight = Theme.rowHeight
        updateBriefColumnWidth()
        updateFrameSize()
        needsDisplay = true
        scrollCursorToVisible()
    }

    // MARK: - In-place rename

    /// Shows an editor over the Name and Ext columns of the cursor row,
    /// with the name selected but not the extension.
    func beginRenaming() {
        guard let item = currentItem, !item.isParent else { return }
        endRenaming()
        scrollCursorToVisible()

        let row = rowRect(cursor)
        var frame = row.insetBy(dx: 0, dy: -1)
        if viewMode == .full {
            let layout = ColumnLayout(width: bounds.width)
            frame.size.width = layout.rect(for: .ext, y: 0, height: 0).maxX
        }
        if viewMode == .thumbnails {
            frame = NSRect(x: row.minX, y: row.minY + Self.thumbnailSize + 8, width: row.width, height: rowHeight + 2)
        } else {
            frame.origin.x += 20
            frame.size.width -= 20
        }
        let field = NSTextField(frame: frame)
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

    var isRenaming: Bool { renameField != nil }

    /// F2 (or Shift+F6) again while renaming selects the next part of the name:
    /// the name, the extension, the whole name.
    func selectNextPartOfName() {
        guard let field = renameField, let editor = field.currentEditor() else { return }
        let text = field.stringValue as NSString
        let all = NSRange(location: 0, length: text.length)
        let dot = text.range(of: ".", options: .backwards)
        guard renamedItem?.isFolder == false, dot.location != NSNotFound, dot.location > 0 else {
            editor.selectedRange = all
            return
        }
        let name = NSRange(location: 0, length: dot.location)
        let ext = NSRange(location: dot.location + 1, length: text.length - dot.location - 1)
        let current = editor.selectedRange
        editor.selectedRange = current == name ? ext : (current == ext ? all : name)
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

    /// The last non-empty selection that was replaced, for "Restore selection".
    private(set) var previousMarks: Set<String> = []

    func setMarked(_ names: Set<String>) {
        if !marked.isEmpty && names != marked {
            previousMarks = marked
        }
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

    /// Num /: marks again what was marked before the last change.
    @objc(cm_RestoreSelection:)
    func restoreSelection(_ sender: Any?) {
        let names = Set(items.map(\.name))
        setMarked(previousMarks.intersection(names))
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

    /// Entries per page: visible rows (Full) or visible columns × rows (Brief, Thumbnails).
    private var visibleRowCount: Int {
        switch viewMode {
        case .full:
            max(Int(visibleRect.height / rowHeight), 1)
        case .brief:
            max(Int(visibleRect.width / briefColumnWidth), 1) * briefRowsPerColumn
        case .thumbnails:
            max(Int(visibleRect.height / thumbnailCell.height), 1) * thumbnailColumns
        }
    }

    static let thumbnailSize: CGFloat = 112

    private var thumbnailCell: NSSize {
        NSSize(width: Self.thumbnailSize + 20, height: Self.thumbnailSize + rowHeight + 14)
    }

    private var thumbnailColumns: Int {
        max(Int((superview?.bounds.width ?? bounds.width) / thumbnailCell.width), 1)
    }

    private var briefRowsPerColumn: Int {
        max(Int((superview?.bounds.height ?? rowHeight) / rowHeight), 1)
    }

    func rowRect(_ row: Int) -> NSRect {
        switch viewMode {
        case .full:
            return NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
        case .brief:
            let rows = briefRowsPerColumn
            return NSRect(x: CGFloat(row / rows) * briefColumnWidth, y: CGFloat(row % rows) * rowHeight,
                          width: briefColumnWidth, height: rowHeight)
        case .thumbnails:
            let cell = thumbnailCell
            let columns = thumbnailColumns
            return NSRect(x: CGFloat(row % columns) * cell.width, y: CGFloat(row / columns) * cell.height,
                          width: cell.width, height: cell.height)
        }
    }

    func index(at point: NSPoint) -> Int? {
        let row = Int(point.y / rowHeight)
        let index: Int
        switch viewMode {
        case .full:
            index = row
        case .brief:
            guard row < briefRowsPerColumn else { return nil }
            index = Int(point.x / briefColumnWidth) * briefRowsPerColumn + row
        case .thumbnails:
            let column = Int(point.x / thumbnailCell.width)
            guard column < thumbnailColumns else { return nil }
            index = Int(point.y / thumbnailCell.height) * thumbnailColumns + column
        }
        return items.indices.contains(index) ? index : nil
    }

    /// Brief columns are as wide as the longest name (within limits).
    private func updateBriefColumnWidth() {
        guard viewMode == .brief else { return }
        let longest = items.map(displayName).max { $0.count < $1.count } ?? ""
        let width = (longest as NSString).size(withAttributes: [.font: Theme.panelFont]).width + 36
        briefColumnWidth = min(max(width, 100), 360).rounded()
    }

    private func displayName(_ item: FileItem) -> String {
        item.isFolder ? "[\(item.name)]" : item.name
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
        let size: NSSize
        switch viewMode {
        case .full:
            size = NSSize(width: superview.bounds.width,
                          height: max(CGFloat(items.count) * rowHeight, superview.bounds.height))
        case .brief:
            let columns = (items.count + briefRowsPerColumn - 1) / briefRowsPerColumn
            size = NSSize(width: max(CGFloat(columns) * briefColumnWidth, superview.bounds.width),
                          height: superview.bounds.height)
            needsDisplay = true
        case .thumbnails:
            let rows = (items.count + thumbnailColumns - 1) / thumbnailColumns
            size = NSSize(width: superview.bounds.width,
                          height: max(CGFloat(rows) * thumbnailCell.height, superview.bounds.height))
            needsDisplay = true
        }
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        dirtyRect.fill()
        guard !items.isEmpty else { return }

        let first: Int
        let last: Int
        switch viewMode {
        case .full:
            first = Int(dirtyRect.minY / rowHeight)
            last = Int(dirtyRect.maxY / rowHeight)
        case .brief:
            first = Int(dirtyRect.minX / briefColumnWidth) * briefRowsPerColumn
            last = (Int(dirtyRect.maxX / briefColumnWidth) + 1) * briefRowsPerColumn - 1
        case .thumbnails:
            first = Int(dirtyRect.minY / thumbnailCell.height) * thumbnailColumns
            last = (Int(dirtyRect.maxY / thumbnailCell.height) + 1) * thumbnailColumns - 1
        }
        let range = max(first, 0)...min(last, items.count - 1)
        guard !range.isEmpty, range.lowerBound <= range.upperBound else { return }
        let layout = ColumnLayout(width: bounds.width)
        for row in range {
            switch viewMode {
            case .full: drawRow(row, layout: layout)
            case .brief: drawBriefCell(row)
            case .thumbnails: drawThumbnailCell(row)
            }
        }
        if let dropTargetRow, items.indices.contains(dropTargetRow) {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: rowRect(dropTargetRow).insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    /// Fills the cursor bar if needed and returns the text color for the entry.
    private func prepareCell(_ row: Int, in rect: NSRect) -> NSColor {
        let filled = row == cursor && isActive
        if !filled && viewMode == .full && row % 2 == 1 && ColorSettings.alternatingRows {
            Theme.alternateRowBackground.setFill()
            rect.fill()
        }
        if filled {
            Theme.cursorBackground.setFill()
            rect.fill()
        }
        let item = items[row]
        let isMarked = marked.contains(item.name)
        return switch (filled, isMarked) {
        case (true, true): Theme.markedCursorText
        case (true, false): Theme.cursorText
        case (false, true): Theme.markedText
        case (false, false): (item.isParent ? nil : ColorSettings.color(forName: item.name)) ?? Theme.panelText
        }
    }

    private func drawIcon(for item: FileItem, in rect: NSRect) {
        FileIcons.icon(for: item).draw(
            in: NSRect(x: rect.minX + 3, y: rect.minY + (rowHeight - 16) / 2, width: 16, height: 16),
            from: .zero, operation: .sourceOver, fraction: item.isHidden ? 0.5 : 1,
            respectFlipped: true, hints: nil
        )
    }

    private func drawInactiveCursorFrame(_ row: Int, in rect: NSRect) {
        guard row == cursor, !isActive else { return }
        Theme.inactiveCursorFrame.setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.setLineDash([1, 1], count: 2, phase: 0)
        frame.stroke()
    }

    private func drawBriefCell(_ row: Int) {
        let item = items[row]
        let rect = rowRect(row)
        let color = prepareCell(row, in: rect)
        drawIcon(for: item, in: rect)
        drawText(displayName(item), in: rect.divided(atDistance: 20, from: .minXEdge).remainder,
                 font: Theme.font(marked: marked.contains(item.name)), color: color)
        drawInactiveCursorFrame(row, in: rect)
    }

    /// A thumbnail with the name underneath; the cursor is a rounded highlight.
    private func drawThumbnailCell(_ row: Int) {
        let item = items[row]
        let rect = rowRect(row)
        let size = Self.thumbnailSize
        if row == cursor {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
            if isActive {
                Theme.cursorBackground.withAlphaComponent(0.3).setFill()
                highlight.fill()
            } else {
                Theme.inactiveCursorFrame.setStroke()
                highlight.setLineDash([2, 2], count: 2, phase: 0)
                highlight.stroke()
            }
        }
        let imageArea = NSRect(x: rect.minX + (rect.width - size) / 2, y: rect.minY + 6, width: size, height: size)
        let image: NSImage
        if item.isParent || item.isFolder {
            image = item.isParent ? FileIcons.icon(for: item) : NSWorkspace.shared.icon(for: .folder)
        } else {
            image = ThumbnailCache.shared.thumbnail(for: item.url, size: size) { [weak self] in
                self?.setNeedsDisplay(rect)
            } ?? NSWorkspace.shared.icon(forFile: item.url.path)
        }
        let scale = min(size / max(image.size.width, 1), size / max(image.size.height, 1), item.isParent ? 1 : 8)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: imageArea.midX - drawn.width / 2, y: imageArea.maxY - drawn.height,
                              width: drawn.width, height: drawn.height),
                   from: .zero, operation: .sourceOver, fraction: item.isHidden ? 0.5 : 1,
                   respectFlipped: true, hints: nil)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let color = marked.contains(item.name) ? Theme.markedText
            : (item.isParent ? nil : ColorSettings.color(forName: item.name)) ?? Theme.panelText
        (displayName(item) as NSString).draw(
            with: NSRect(x: rect.minX + 4, y: imageArea.maxY + 4, width: rect.width - 8, height: rowHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: Theme.font(marked: marked.contains(item.name)), .foregroundColor: color,
                         .paragraphStyle: paragraph]
        )
    }

    private func drawRow(_ row: Int, layout: ColumnLayout) {
        let item = items[row]
        let rect = rowRect(row)
        let color = prepareCell(row, in: rect)
        let y = rect.minY
        let isMarked = marked.contains(item.name)
        let textFont = Theme.font(marked: isMarked)
        // Sizes and dates stay regular: in bold they would not fit their columns.
        let numberFont = Theme.panelNumberFont

        let nameRect = layout.rect(for: .name, y: y, height: rowHeight)
        drawIcon(for: item, in: nameRect)
        let name = item.isFolder ? "[\(item.baseName)]" : item.baseName
        drawText(name, in: nameRect.divided(atDistance: 20, from: .minXEdge).remainder,
                 font: textFont, color: color)

        drawText(item.fileExtension, in: layout.rect(for: .ext, y: y, height: rowHeight),
                 font: textFont, color: color)

        let size: String
        if item.isFolder, let folderSize = folderSizes[item.name] {
            size = folderSize.formatted(.number.grouping(.automatic))
        } else if item.isFolder {
            size = "<DIR>"
        } else if item.isPackage {
            size = "<PKG>"
        } else {
            size = item.size.formatted(.number.grouping(.automatic))
        }
        drawText(size, in: layout.rect(for: .size, y: y, height: rowHeight),
                 font: numberFont, color: color, alignment: .right)

        if !item.isParent {
            for column in layout.extraColumns {
                let value = MetadataCache.shared.cachedValue(for: item, column: column) { [weak self] in
                    self?.setNeedsDisplay(rect)
                }
                let numeric = column == .dimensions || column == .duration
                drawText(value?.display ?? "", in: layout.rect(for: column, y: y, height: rowHeight),
                         font: numeric || column == .created ? numberFont : textFont,
                         color: color, alignment: numeric ? .right : .left)
            }
            drawText(Self.dateFormatter.string(from: item.modified),
                     in: layout.rect(for: .date, y: y, height: rowHeight),
                     font: numberFont, color: color)
            if layout.contains(.attr) {
                drawText(item.permissions, in: layout.rect(for: .attr, y: y, height: rowHeight),
                         font: numberFont, color: color)
            }
        }

        drawInactiveCursorFrame(row, in: rect)
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
        dragOrigin = nil
        guard let row = index(at: point) else { return }
        dragOrigin = (point, row)
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

    /// How long the right button is held still on a file for the context menu when
    /// it marks files.
    private static let menuHoldTime: TimeInterval = 0.5

    /// When the right button marks files (Settings → Panels): a click marks or unmarks
    /// the file, a drag over files makes them all as the first one became, holding the
    /// button still shows the context menu. Elsewhere, the menu at once.
    override func rightMouseDown(with event: NSEvent) {
        guard Settings.rightButton == .marks, let window,
              let row = index(at: convert(event.locationInWindow, from: nil)), !items[row].isParent else {
            super.rightMouseDown(with: event)
            return
        }
        window.makeFirstResponder(self)
        let mark = !marked.contains(items[row].name)
        let deadline = Date(timeIntervalSinceNow: Self.menuHoldTime)
        var last: Int?
        while true {
            guard let next = window.nextEvent(matching: [.rightMouseUp, .rightMouseDragged],
                                              until: last == nil ? deadline : .distantFuture,
                                              inMode: .eventTracking, dequeue: true) else {
                if let menu = menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                }
                return
            }
            if next.type == .rightMouseUp {
                if last == nil {
                    setMarks(mark, from: row, to: row)
                    moveCursor(to: row)
                }
                return
            }
            // Moving within the first file is still a click (or a hold).
            guard let current = index(at: convert(next.locationInWindow, from: nil)),
                  current != (last ?? row) else { continue }
            setMarks(mark, from: last ?? row, to: current)
            moveCursor(to: current)
            last = current
        }
    }

    private func setMarks(_ mark: Bool, from start: Int, to end: Int) {
        let names = items[min(start, end)...max(start, end)].filter { !$0.isParent }.map(\.name)
        if mark {
            marked.formUnion(names)
        } else {
            marked.subtract(names)
        }
        needsDisplay = true
        delegate?.fileListMarksDidChange(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if delegate?.fileList(self, interceptKey: event) == true { return }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        switch (event.specialKey, modifiers) {
        case (.upArrow?, []) where viewMode == .thumbnails:
            moveCursor(to: cursor - thumbnailColumns)
        case (.downArrow?, []) where viewMode == .thumbnails:
            moveCursor(to: min(cursor + thumbnailColumns, items.count - 1))
        case (.leftArrow?, []) where viewMode == .thumbnails:
            moveCursor(to: cursor - 1)
        case (.rightArrow?, []) where viewMode == .thumbnails:
            moveCursor(to: cursor + 1)
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
        case (.leftArrow?, []) where viewMode == .brief:
            moveCursor(to: cursor - briefRowsPerColumn)
        case (.rightArrow?, []) where viewMode == .brief:
            moveCursor(to: min(cursor + briefRowsPerColumn, items.count - 1))
        case (.leftArrow?, [.shift]) where viewMode == .brief:
            markRangeAndMove(to: max(cursor - briefRowsPerColumn, 0))
        case (.rightArrow?, [.shift]) where viewMode == .brief:
            markRangeAndMove(to: min(cursor + briefRowsPerColumn, items.count - 1))
        case (.carriageReturn?, []), (.enter?, []), (.downArrow?, [.command]):
            delegate?.fileList(self, openItemAt: cursor)
        case (.pageDown?, [.control]):
            delegate?.fileList(self, enterItemAt: cursor)
        case (.delete?, []), (.upArrow?, [.command]), (.pageUp?, [.control]):
            delegate?.fileListGoToParent(self)
        case (.tab?, []), (.tab?, [.shift]), (.backTab?, _):
            delegate?.fileListSwitchPanel(self)
        // Option/Control arrows edit text elsewhere, so they are panel-only keys.
        case (.leftArrow?, [.option]):
            tryToPerform(Command.goToPrevDir.selector, with: self)
        case (.rightArrow?, [.option]):
            tryToPerform(Command.goToNextDir.selector, with: self)
        case (.downArrow?, [.option]):
            tryToPerform(Command.directoryHistory.selector, with: self)
        case (.upArrow?, [.control]), (.upArrow?, [.command, .option]):
            tryToPerform(Command.openDirInNewTab.selector, with: self)
        case (nil, [.option]) where ["+", "=", "-"].contains(event.charactersIgnoringModifiers ?? ""):
            // Total Commander's Alt+Num+ / Alt+Num−.
            let select = event.charactersIgnoringModifiers != "-"
            tryToPerform(select ? Command.selectCurrentExtension.selector : Command.unselectCurrentExtension.selector,
                         with: self)
        case (nil, [.option]), (nil, [.control, .option]):
            if let text = event.charactersIgnoringModifiers, !text.isEmpty,
               text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                delegate?.fileList(self, beginQuickSearchWith: text)
            } else {
                super.keyDown(with: event)
            }
        case (nil, [.control]) where ["c", "x", "v"].contains(event.shortcutCharacters ?? ""):
            // Total Commander's Ctrl+C / Ctrl+X / Ctrl+V for files.
            let action = switch event.shortcutCharacters {
            case "c": #selector(NSText.copy(_:))
            case "x": #selector(NSText.cut(_:))
            default: #selector(NSText.paste(_:))
            }
            tryToPerform(action, with: self)
        case (nil, [.control]) where event.shortcutCharacters == "f":
            tryToPerform(Command.ftpConnect.selector, with: self)
        case (nil, [.control]) where event.shortcutCharacters == "b":
            tryToPerform(Command.branchView.selector, with: self)
        case (nil, [.control]) where event.shortcutCharacters == "d":
            tryToPerform(Command.directoryHotlist.selector, with: self)
        case (.leftArrow?, [.control]), (.leftArrow?, [.command, .option]):
            tryToPerform(Command.transferLeft.selector, with: self)
        case (.rightArrow?, [.control]), (.rightArrow?, [.command, .option]):
            tryToPerform(Command.transferRight.selector, with: self)
        case (.deleteForward?, []), (.delete?, [.command]):
            tryToPerform(Command.delete.selector, with: self)
        // With Shift (or ⌥⌘⌫, the Finder's "Delete Immediately"): past the Trash.
        case (.deleteForward?, [.shift]), (.delete?, [.shift]), (.delete?, [.command, .shift]),
             (.delete?, [.command, .option]):
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
        case " ":
            if let item = currentItem, item.isFolder, !item.isParent, folderSizes[item.name] == nil {
                delegate?.fileList(self, calculateSizeOf: item)
            }
            toggleMarkAndMove(by: 1)
        case "+": spreadSelection(nil)
        case "-": shrinkSelection(nil)
        case "*": exchangeSelection(nil)
        case "/": restoreSelection(nil)
        case "\u{1b}": tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: self)
        case let text? where Settings.quickSearchMode == .letters && !text.isEmpty
            && text.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value != 0x7F && $0.value < 0xF700 }):
            delegate?.fileList(self, beginQuickSearchWith: text)
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
