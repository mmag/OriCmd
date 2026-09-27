import AppKit

/// Total Commander's "Compare by content": two files side by side, aligned
/// line by line, with the differences highlighted. Binary files are compared
/// as hex dumps, byte position against byte position.
///
/// Keys: N / P or ⌥↓ / ⌥↑ next / previous difference, Esc closes.
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [CompareWindowController] = []
    private nonisolated static let textLimit = 16 * 1024 * 1024
    private nonisolated static let binaryLimit = 64 * 1024 * 1024
    private nonisolated static let bytesPerLine = 16

    /// What is shown: lines of text, or the bytes of both files as hex dump lines.
    private enum Content {
        case text(left: [Substring], right: [Substring])
        case binary(left: Data, right: Data)
    }

    private let leftURL: URL
    private let rightURL: URL
    private var content = Content.text(left: [], right: [])
    private var rows: [TextDiff.Row] = []
    private var blocks: [Int] = []
    private var truncated = false

    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let whitespaceBox = NSButton(checkboxWithTitle: String(localized: "Ignore whitespace"), target: nil, action: nil)
    private let detail = NSTextView()
    private let textFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let binaryFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private var font: NSFont {
        if case .binary = content { binaryFont } else { textFont }
    }

    /// Opens a window comparing `left` with `right`.
    static func show(_ left: URL, _ right: URL) {
        let controller = CompareWindowController(left: left, right: right)
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.reload()
    }

    private init(left: URL, right: URL) {
        leftURL = left
        rightURL = right
        let window = CompareWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = String(localized: "Compare: \(left.lastPathComponent) — \(right.lastPathComponent)")
        window.rememberFrame(as: "Compare")
        window.center()
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
    }

    // MARK: - Layout

    private func buildContent() {
        for (identifier, width) in [("leftNumber", 50.0), ("left", 480.0), ("rightNumber", 50.0), ("right", 480.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            if identifier.hasSuffix("Number") {
                column.minWidth = 30
                column.maxWidth = 90
                column.resizingMask = .userResizingMask
            } else {
                column.resizingMask = .autoresizingMask
            }
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ceil(textFont.ascender - textFont.descender + textFont.leading) + 3
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let leftPath = NSTextField(labelWithString: leftURL.path)
        let rightPath = NSTextField(labelWithString: rightURL.path)
        for label in [leftPath, rightPath] {
            label.lineBreakMode = .byTruncatingHead
            label.font = .systemFont(ofSize: 11)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let paths = NSStackView(views: [leftPath, rightPath])
        paths.distribution = .fillEqually

        whitespaceBox.target = self
        whitespaceBox.action = #selector(reloadFromControl(_:))
        let previous = NSButton(title: String(localized: "Previous Difference"), target: self,
                                action: #selector(previousDifference(_:)))
        let next = NSButton(title: String(localized: "Next Difference"), target: self, action: #selector(nextDifference(_:)))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [previous, next, whitespaceBox, statusLabel])
        bar.spacing = 12

        detail.isEditable = false
        detail.font = textFont
        detail.textContainerInset = NSSize(width: 4, height: 4)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detail.autoresizingMask = [.width]
        detailScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [bar, paths, scrollView, detailScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        for view in [paths, scrollView, detailScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
        window?.initialFirstResponder = table
    }

    // MARK: - Loading

    @objc private func reloadFromControl(_ sender: Any?) {
        reload()
    }

    private func reload() {
        statusLabel.stringValue = String(localized: "Comparing…")
        let (left, right) = (leftURL, rightURL)
        let ignoringWhitespace = whitespaceBox.state == .on
        Task {
            let result = await Self.compare(left, right, ignoringWhitespace: ignoringWhitespace)
            content = result.content
            rows = result.rows
            truncated = result.truncated
            blocks = TextDiff.blockStarts(rows)
            let isText = if case .text = content { true } else { false }
            whitespaceBox.isEnabled = isText
            // Hex dump lines carry their offsets.
            for column in table.tableColumns where column.identifier.rawValue.hasSuffix("Number") {
                column.isHidden = !isText
            }
            table.sizeToFit()
            table.reloadData()
            updateStatus()
            if let first = blocks.first {
                select(row: first)
            } else if !rows.isEmpty {
                select(row: 0)
            }
            window?.makeFirstResponder(table)
        }
    }

    @concurrent
    private nonisolated static func compare(_ left: URL, _ right: URL, ignoringWhitespace: Bool) async
        -> (content: Content, rows: [TextDiff.Row], truncated: Bool) {
        let (leftData, leftSize) = head(of: left, limit: binaryLimit)
        let (rightData, rightSize) = head(of: right, limit: binaryLimit)
        if TextDecoding.looksLikeText(leftData), TextDecoding.looksLikeText(rightData),
           leftData.count <= textLimit, rightData.count <= textLimit {
            let leftLines = TextDiff.lines(of: TextDecoding.string(from: leftData))
            let rightLines = TextDiff.lines(of: TextDecoding.string(from: rightData))
            let rows = TextDiff.rows(leftLines, rightLines, ignoringWhitespace: ignoringWhitespace)
            return (.text(left: leftLines, right: rightLines), rows, false)
        }
        let rows = TextDiff.binaryRows(leftData, rightData, bytesPerLine: bytesPerLine)
        return (.binary(left: leftData, right: rightData), rows, leftSize > leftData.count || rightSize > rightData.count)
    }

    private nonisolated static func head(of url: URL, limit: Int) -> (data: Data, size: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: 0)
        return ((try? handle.read(upToCount: limit)) ?? Data(), size)
    }

    private func updateStatus() {
        var status = blocks.isEmpty
            ? String(localized: "No differences")
            : String(localized: "Differences: \(blocks.count)")
        if case .binary = content {
            status += " · " + String(localized: "binary comparison")
        }
        if truncated {
            status += " · " + String(localized: "only the first 64 MB are compared")
        }
        if let row = rows.indices.contains(table.selectedRow) ? table.selectedRow : nil,
           let block = blocks.lastIndex(where: { $0 <= row }), rows[row].kind != .same {
            status = String(localized: "Difference \(block + 1) of \(blocks.count)") + " · " + status
        }
        statusLabel.stringValue = status
    }

    // MARK: - Navigation

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.specialKey, modifiers) {
        case (.downArrow?, [.option]): nextDifference(nil)
        case (.upArrow?, [.option]): previousDifference(nil)
        default:
            guard modifiers.isEmpty else { return false }
            switch event.shortcutCharacters {
            case "n": nextDifference(nil)
            case "p": previousDifference(nil)
            case "\u{1b}": window?.close()
            default: return false
            }
        }
        return true
    }

    @objc private func nextDifference(_ sender: Any?) {
        guard let row = blocks.first(where: { $0 > table.selectedRow }) else {
            NSSound.beep()
            return
        }
        select(row: row)
    }

    @objc private func previousDifference(_ sender: Any?) {
        let current = blocks.lastIndex(where: { $0 <= table.selectedRow }).map { blocks[$0] } ?? -1
        let target = rows.indices.contains(table.selectedRow) && rows[table.selectedRow].kind != .same && current >= 0
            ? blocks.last(where: { $0 < current })
            : blocks.last(where: { $0 < table.selectedRow })
        guard let target else {
            NSSound.beep()
            return
        }
        select(row: target)
    }

    private func select(row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        // Some context above the difference.
        table.scrollRowToVisible(min(row + 8, rows.count - 1))
        table.scrollRowToVisible(max(row - 3, 0))
    }

    // MARK: - Text of the rows

    private func line(_ index: Int?, left: Bool) -> String? {
        guard let index else { return nil }
        switch content {
        case .text(let leftLines, let rightLines):
            let lines = left ? leftLines : rightLines
            return lines.indices.contains(index) ? String(lines[index]).replacingOccurrences(of: "\t", with: "    ") : nil
        case .binary(let leftData, let rightData):
            return Self.hexLine(left ? leftData : rightData, line: index)
        }
    }

    private static func hexLine(_ data: Data, line: Int) -> String {
        let start = data.startIndex + line * bytesPerLine
        guard start < data.endIndex else { return "" }
        let bytes = data[start..<min(start + bytesPerLine, data.endIndex)]
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let padded = hex.padding(toLength: bytesPerLine * 3 - 1, withPad: " ", startingAt: 0)
        let ascii = String(bytes.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return String(format: "%08X", line * bytesPerLine) + "  " + padded + "  " + ascii
    }

    private func background(for kind: TextDiff.Kind, present: Bool) -> NSColor? {
        guard present else { return NSColor.gray.withAlphaComponent(0.12) }
        return switch kind {
        case .same: nil
        case .changed: NSColor.systemYellow.withAlphaComponent(0.22)
        case .leftOnly: NSColor.systemRed.withAlphaComponent(0.18)
        case .rightOnly: NSColor.systemGreen.withAlphaComponent(0.18)
        }
    }

    /// `text` with the changed parts highlighted; `ranges` start after `offset` characters.
    private func attributedLine(_ text: String, highlighting ranges: [NSRange], offset: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for range in ranges where range.length > 0 && offset + NSMaxRange(range) <= result.length {
            result.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.45),
                                range: NSRange(location: offset + range.location, length: range.length))
        }
        return result
    }

    /// What differs within a changed row: the middle of a text line, or each differing byte.
    private func changedRanges(of row: TextDiff.Row, left: String?, right: String?) -> (left: [NSRange], right: [NSRange]) {
        guard row.kind == .changed, let left, let right else { return ([], []) }
        switch content {
        case .text:
            guard left.utf16.count < 5000, right.utf16.count < 5000 else { return ([], []) }
            let (leftRange, rightRange) = TextDiff.changedRanges(left, right)
            return ([leftRange], [rightRange])
        case .binary(let leftData, let rightData):
            guard let line = row.left else { return ([], []) }
            let start = line * Self.bytesPerLine
            var ranges: [NSRange] = []
            for column in 0..<Self.bytesPerLine {
                let a = leftData.count > start + column ? leftData[leftData.startIndex + start + column] : nil
                let b = rightData.count > start + column ? rightData[rightData.startIndex + start + column] : nil
                guard a != b else { continue }
                // "00001380  0D C0 …" — hex pairs after the offset, the ASCII column after them.
                ranges.append(NSRange(location: 10 + column * 3, length: 2))
                ranges.append(NSRange(location: 10 + Self.bytesPerLine * 3 + 1 + column, length: 1))
            }
            return (ranges, ranges)
        }
    }

    private func updateDetail() {
        guard rows.indices.contains(table.selectedRow) else {
            detail.string = ""
            return
        }
        let row = rows[table.selectedRow]
        let left = line(row.left, left: true)
        let right = line(row.right, left: false)
        let ranges = changedRanges(of: row, left: left, right: right)
        let text = NSMutableAttributedString()
        text.append(attributedLine("< " + (left ?? ""), highlighting: ranges.left, offset: 2))
        text.append(NSAttributedString(string: "\n"))
        text.append(attributedLine("> " + (right ?? ""), highlighting: ranges.right, offset: 2))
        detail.textStorage?.setAttributedString(text)
    }
}

extension CompareWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byClipping
            field.drawsBackground = true
            field.cell?.truncatesLastVisibleLine = true
            return field
        }()
        let diffRow = rows[row]
        let isLeft = identifier.rawValue.hasPrefix("left")
        let index = isLeft ? diffRow.left : diffRow.right
        field.backgroundColor = background(for: diffRow.kind, present: index != nil) ?? .clear
        if identifier.rawValue.hasSuffix("Number") {
            field.font = font
            field.alignment = .right
            field.textColor = .secondaryLabelColor
            field.stringValue = index.map { String($0 + 1) + " " } ?? ""
        } else {
            let left = line(diffRow.left, left: true)
            let right = line(diffRow.right, left: false)
            let ranges = changedRanges(of: diffRow, left: left, right: right)
            let text = " " + ((isLeft ? left : right) ?? "")
            field.attributedStringValue = attributedLine(text, highlighting: isLeft ? ranges.left : ranges.right, offset: 1)
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
        updateStatus()
    }
}

/// Lets the window handle N / P / Esc before the table sees them.
private final class CompareWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
