import AppKit

/// The Lister's table view: a grid with spreadsheet column letters and row numbers,
/// and the sheets to choose from above it when there are several. ⌘C copies the
/// selected rows as tab-separated text (Excel and Numbers paste it as cells).
final class TableGridView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Columns past this many are not shown (a view of that many is too slow).
    private static let maxShownColumns = 1024

    private let table: ViewerTable
    private var sheet = 0
    private let grid = GridTableView()
    private let scrollView = NSScrollView()
    private let sheets = NSSegmentedControl()
    private let rowNumber = NSUserInterfaceItemIdentifier("row")

    init(table: ViewerTable) {
        self.table = table
        super.init(frame: .zero)
        grid.dataSource = self
        grid.delegate = self
        grid.usesAlternatingRowBackgroundColors = true
        grid.gridStyleMask = [.solidVerticalGridLineMask]
        grid.allowsMultipleSelection = true
        grid.allowsColumnReordering = false
        grid.rowHeight = 20
        grid.style = .plain
        grid.copyRows = { [weak self] rows in self?.text(ofRows: rows) ?? "" }
        scrollView.documentView = grid
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let views: [NSView]
        if table.sheets.count > 1 {
            sheets.segmentCount = table.sheets.count
            for (index, sheet) in table.sheets.enumerated() {
                sheets.setLabel(sheet.name.isEmpty ? String(localized: "Table \(index + 1)") : sheet.name, forSegment: index)
            }
            sheets.selectedSegment = 0
            sheets.target = self
            sheets.action = #selector(sheetChosen(_:))
            sheets.segmentDistribution = .fit
            views = [sheets, scrollView]
        } else {
            views = [scrollView]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: table.sheets.count > 1 ? 6 : 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showSheet(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The grid takes the keys (arrows, ⌘C, ⌘A).
    var firstResponderView: NSView { grid }

    @objc private func sheetChosen(_ sender: NSSegmentedControl) {
        showSheet(sender.selectedSegment)
    }

    private var current: ViewerTable.Sheet { table.sheets[sheet] }

    private func showSheet(_ index: Int) {
        sheet = index
        for column in grid.tableColumns.reversed() {
            grid.removeTableColumn(column)
        }
        let numbers = NSTableColumn(identifier: rowNumber)
        numbers.title = ""
        numbers.width = CGFloat(String(current.rowCount).count) * 8 + 16
        grid.addTableColumn(numbers)
        let sampled = 0..<min(current.rowCount, 200)
        for index in 0..<min(current.columnCount, Self.maxShownColumns) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = ViewerTable.columnName(index)
            column.headerCell.alignment = .center
            // About as wide as the longest of the first texts (character count, up to a limit).
            let longest = sampled.map { current.text(row: $0, column: index)?.prefix(45).count ?? 0 }.max() ?? 0
            column.width = CGFloat(min(max(longest * 7 + 12, 48), 320))
            column.minWidth = 24
            grid.addTableColumn(column)
        }
        grid.reloadData()
        grid.scrollRowToVisible(0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        current.rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let isNumber = tableColumn.identifier == rowNumber
        let identifier = NSUserInterfaceItemIdentifier(isNumber ? "number" : "cell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.font = .systemFont(ofSize: 12)
            if isNumber {
                field.textColor = .secondaryLabelColor
                field.alignment = .right
            }
            return field
        }()
        if isNumber {
            field.stringValue = String(row + 1)
        } else {
            let text = Int(tableColumn.identifier.rawValue).flatMap { current.text(row: row, column: $0) } ?? ""
            // One line: line breaks inside a cell shown as spaces.
            field.stringValue = text.contains(where: \.isNewline)
                ? text.split(whereSeparator: \.isNewline).joined(separator: " ") : text
            field.toolTip = text.count > 40 ? text : nil
            // Numbers to the right, as in spreadsheets.
            field.alignment = Self.isNumber(text) ? .right : .left
        }
        return field
    }

    /// 1 234,50 or -12.5 or 7%: digits with a sign, spaces between thousands, a
    /// decimal comma or point.
    private static func isNumber(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count <= 32, compact.contains(where: \.isNumber) else { return false }
        var body = Substring(compact)
        if body.hasSuffix("%") { body = body.dropLast() }
        return Double(body.replacingOccurrences(of: ",", with: ".")) != nil
    }

    /// The rows' cells, tab-separated, a line each: at most 100 000 rows and 32 MB
    /// (columns up to the last one with a text in the row).
    private func text(ofRows rows: IndexSet) -> String {
        var lines: [String] = []
        var size = 0
        for row in rows.prefix(100_000) {
            let cells = current.rows[row] ?? [:]
            let last = min(cells.keys.max() ?? -1, Self.maxShownColumns - 1)
            let line = last < 0 ? "" : (0...last).map { cells[$0] ?? "" }.joined(separator: "\t")
            size += line.utf8.count + 1
            if size > 32 * 1024 * 1024 { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Copies the selected rows (⌘C).
private final class GridTableView: NSTableView {
    var copyRows: ((IndexSet) -> String)?

    @objc func copy(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty, let copyRows else {
            NSSound.beep()
            return
        }
        let pasteboard = AppDefaults.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(copyRows(selectedRowIndexes), forType: .string)
    }
}
