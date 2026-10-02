import AppKit

/// Total Commander's "Compare by content": two files side by side, aligned
/// line by line, with the differences highlighted. Binary files are compared
/// as hex dumps, byte position against byte position.
///
/// Text files can be edited: a difference copied to the other side, a line
/// changed, then saved as it was written (encoding, line breaks).
///
/// Keys: N / P or ⌥↓ / ⌥↑ next / previous difference, ⌘S saves, Esc closes.
final class CompareWindowController: NSWindowController, NSWindowDelegate, HandlesEscapeKey {
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
    /// How each text file was written, to save it the same way.
    private var formats: (left: TextFormat, right: TextFormat)?
    /// The sides changed and not saved yet.
    private var edited: (left: Bool, right: Bool) = (false, false)

    /// A text file's encoding, byte order mark, line breaks and final line break.
    private nonisolated struct TextFormat: Sendable {
        let encoding: TextEncoding
        let hasByteOrderMark: Bool
        let bigEndian: Bool
        let lineBreak: String
        let endsWithLineBreak: Bool

        init(_ data: Data, text: String, encodingName: String) {
            encoding = TextEncoding.allCases.first { $0.title == encodingName } ?? .utf8
            hasByteOrderMark = data.starts(with: [0xEF, 0xBB, 0xBF]) || data.starts(with: [0xFF, 0xFE])
                || data.starts(with: [0xFE, 0xFF])
            bigEndian = data.starts(with: [0xFE, 0xFF])
            lineBreak = text.contains("\r\n") ? "\r\n" : text.contains("\r") && !text.contains("\n") ? "\r" : "\n"
            endsWithLineBreak = text.last?.isNewline ?? false
        }

        /// The lines as this file had them written; nil if the encoding has no
        /// letters for some of them.
        func data(of lines: [Substring]) -> Data? {
            let text = lines.joined(separator: lineBreak) + (endsWithLineBreak && !lines.isEmpty ? lineBreak : "")
            switch encoding {
            case .utf8, .automatic:
                return (hasByteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
            case .utf16:
                let encoded = TextDecoding.encoded(text, as: .utf16)
                guard encoded.count == 2 else { return nil }
                return (bigEndian ? Data([0xFE, 0xFF]) : Data([0xFF, 0xFE])) + encoded[bigEndian ? 1 : 0]
            default:
                return TextDecoding.encoded(text, as: encoding).first
            }
        }
    }

    private let toRightButton = NSButton(title: String(localized: "Copy to Right →"), target: nil, action: nil)
    private let toLeftButton = NSButton(title: String(localized: "← Copy to Left"), target: nil, action: nil)
    private let editButton = NSButton(title: String(localized: "Edit Line…"), target: nil, action: nil)
    private let saveButton = NSButton(title: String(localized: "Save"), target: nil, action: nil)

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
        for (button, action, name) in [(toRightButton, #selector(copyToRight(_:)), "compareToRight"),
                                       (toLeftButton, #selector(copyToLeft(_:)), "compareToLeft"),
                                       (editButton, #selector(editLine(_:)), "compareEdit"),
                                       (saveButton, #selector(save(_:)), "compareSave")] {
            button.target = self
            button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(name)
        }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        table.target = self
        table.doubleAction = #selector(editLine(_:))
        let bar = NSStackView(views: [previous, next, whitespaceBox, toRightButton, toLeftButton, editButton, saveButton,
                                      statusLabel])
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
            formats = result.formats
            edited = (false, false)
            updateEditing()
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
        -> (content: Content, rows: [TextDiff.Row], truncated: Bool, formats: (left: TextFormat, right: TextFormat)?) {
        let (leftData, leftSize) = head(of: left, limit: binaryLimit)
        let (rightData, rightSize) = head(of: right, limit: binaryLimit)
        if TextDecoding.looksLikeText(leftData), TextDecoding.looksLikeText(rightData),
           leftData.count <= textLimit, rightData.count <= textLimit {
            let leftText = TextDecoding.decode(leftData, as: .automatic)
            let rightText = TextDecoding.decode(rightData, as: .automatic)
            let leftLines = TextDiff.lines(of: leftText.text)
            let rightLines = TextDiff.lines(of: rightText.text)
            let rows = TextDiff.rows(leftLines, rightLines, ignoringWhitespace: ignoringWhitespace)
            return (.text(left: leftLines, right: rightLines), rows, false,
                    (TextFormat(leftData, text: leftText.text, encodingName: leftText.name),
                     TextFormat(rightData, text: rightText.text, encodingName: rightText.name)))
        }
        let rows = TextDiff.binaryRows(leftData, rightData, bytesPerLine: bytesPerLine)
        return (.binary(left: leftData, right: rightData), rows, leftSize > leftData.count || rightSize > rightData.count, nil)
    }

    // MARK: - Editing

    /// Only text files can be changed here.
    private var isEditable: Bool { formats != nil }

    private func updateEditing() {
        for button in [toRightButton, toLeftButton, editButton] {
            button.isEnabled = isEditable
        }
        saveButton.isEnabled = edited.left || edited.right
        window?.isDocumentEdited = edited.left || edited.right
    }

    /// The rows of the difference the selection is in (nil on equal lines).
    private var selectedBlock: ClosedRange<Int>? {
        let row = table.selectedRow
        guard rows.indices.contains(row), rows[row].kind != .same else { return nil }
        var start = row
        var end = row
        while start > 0, rows[start - 1].kind != .same { start -= 1 }
        while end < rows.count - 1, rows[end + 1].kind != .same { end += 1 }
        return start...end
    }

    @objc private func copyToRight(_ sender: Any?) {
        copyBlock(toRight: true)
    }

    @objc private func copyToLeft(_ sender: Any?) {
        copyBlock(toRight: false)
    }

    /// The difference's lines of one side put in place of the other side's (a
    /// side without lines there removes them).
    private func copyBlock(toRight: Bool) {
        guard isEditable, case .text(let left, let right) = content, let block = selectedBlock else {
            NSSound.beep()
            return
        }
        let source = toRight ? left : right
        var target = toRight ? right : left
        let sourceIndices = rows[block].compactMap { toRight ? $0.left : $0.right }
        let targetIndices = rows[block].compactMap { toRight ? $0.right : $0.left }
        let lines = sourceIndices.map { source[$0] }
        if let first = targetIndices.min(), let last = targetIndices.max() {
            target.replaceSubrange(first...last, with: lines)
        } else {
            target.insert(contentsOf: lines, at: insertionIndex(before: block.lowerBound, right: toRight))
        }
        update(left: toRight ? left : target, right: toRight ? target : right, select: block.lowerBound)
        if toRight { edited.right = true } else { edited.left = true }
        updateEditing()
    }

    /// Where a line goes on one side before `row`: after the last line that side
    /// has above it.
    private func insertionIndex(before row: Int, right: Bool) -> Int {
        rows[..<row].reversed().lazy.compactMap { right ? $0.right : $0.left }.first.map { $0 + 1 } ?? 0
    }

    /// Both lines of the selected row, to change; one side without a line gets
    /// the text as a new line.
    @objc private func editLine(_ sender: Any?) {
        guard isEditable, let window, case .text(let left, let right) = content,
              rows.indices.contains(table.selectedRow) else {
            NSSound.beep()
            return
        }
        let rowIndex = table.selectedRow
        let row = rows[rowIndex]
        let leftField = NSTextField(string: row.left.map { String(left[$0]) } ?? "")
        let rightField = NSTextField(string: row.right.map { String(right[$0]) } ?? "")
        leftField.placeholderString = String(localized: "(no line)")
        rightField.placeholderString = String(localized: "(no line)")
        leftField.identifier = NSUserInterfaceItemIdentifier("compareLeftLine")
        rightField.identifier = NSUserInterfaceItemIdentifier("compareRightLine")
        for field in [leftField, rightField] {
            field.font = textFont
            field.widthAnchor.constraint(equalToConstant: 520).isActive = true
        }
        let grid = NSGridView(views: [[NSTextField(labelWithString: leftURL.lastPathComponent), leftField],
                                      [NSTextField(labelWithString: rightURL.lastPathComponent), rightField]])
        grid.rowSpacing = 6
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let alert = NSAlert()
        alert.messageText = String(localized: "Edit Line")
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addCancelButton()
        alert.window.initialFirstResponder = leftField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, case .text(var left, var right) = content else { return }
            var changed = (left: false, right: false)
            for (field, isLeft) in [(leftField, true), (rightField, false)] {
                let index = isLeft ? row.left : row.right
                let text = Substring(field.stringValue)
                if let index {
                    guard (isLeft ? left[index] : right[index]) != text else { continue }
                    if isLeft { left[index] = text } else { right[index] = text }
                } else if !text.isEmpty {
                    let at = insertionIndex(before: rowIndex, right: !isLeft)
                    if isLeft { left.insert(text, at: at) } else { right.insert(text, at: at) }
                } else {
                    continue
                }
                if isLeft { changed.left = true } else { changed.right = true }
            }
            guard changed.left || changed.right else { return }
            update(left: left, right: right, select: rowIndex)
            edited = (edited.left || changed.left, edited.right || changed.right)
            updateEditing()
        }
    }

    /// Compares the changed lines again, the selection kept near `row`.
    private func update(left: [Substring], right: [Substring], select row: Int) {
        content = .text(left: left, right: right)
        rows = TextDiff.rows(left, right, ignoringWhitespace: whitespaceBox.state == .on)
        blocks = TextDiff.blockStarts(rows)
        table.reloadData()
        updateStatus()
        if !rows.isEmpty { select(row: min(row, rows.count - 1)) }
    }

    /// ⌘S: writes the changed sides as they were written, in place.
    @objc private func save(_ sender: Any?) {
        _ = saveChanges()
    }

    /// Whether everything changed is saved (an error is shown otherwise).
    private func saveChanges() -> Bool {
        guard let formats, case .text(let left, let right) = content else { return true }
        for (isLeft, url, format, lines) in [(true, leftURL, formats.left, left), (false, rightURL, formats.right, right)]
            where isLeft ? edited.left : edited.right {
            guard let data = format.data(of: lines) else {
                Prompt.info(String(localized: "Cannot save \u{201C}\(url.lastPathComponent)\u{201D}"),
                            message: String(localized: "Some of its letters cannot be written in \(format.encoding.title)."),
                            in: window)
                return false
            }
            do {
                try data.write(to: url)
            } catch {
                Prompt.error(String(localized: "Cannot save \u{201C}\(url.lastPathComponent)\u{201D}"), error, in: window)
                return false
            }
            if isLeft { edited.left = false } else { edited.right = false }
        }
        updateEditing()
        return true
    }

    /// Unsaved changes: asked whether to save them first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard edited.left || edited.right else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the changes?")
        alert.informativeText = String(localized: "The compared files were changed here.")
        alert.addButton(withTitle: String(localized: "Save"))
        let discard = alert.addButton(withTitle: String(localized: "Don't Save"))
        discard.hasDestructiveAction = true
        alert.addCancelButton()
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if saveChanges() { sender.close() }
            case .alertSecondButtonReturn:
                edited = (false, false)
                sender.close()
            default:
                break
            }
        }
        return false
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
            case "\u{1b}": window?.performClose(nil)
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
