import AppKit

/// Alt+F7: Total Commander's "Find Files" dialog.
final class FindFilesWindowController: NSWindowController {
    private static var shared: FindFilesWindowController?

    private let maskField = NSTextField(string: "*")
    private let directoryField = NSTextField(string: "")
    private let textField = NSTextField(string: "")
    private let caseSensitiveBox = NSButton(checkboxWithTitle: String(localized: "Case sensitive"), target: nil, action: nil)
    private let nameRegexBox = NSButton(checkboxWithTitle: String(localized: "Regular expression instead of masks"),
                                        target: nil, action: nil)
    private let wholeWordsBox = NSButton(checkboxWithTitle: String(localized: "Whole words"), target: nil, action: nil)
    private let textRegexBox = NSButton(checkboxWithTitle: String(localized: "Regular expression"), target: nil, action: nil)
    private let notContainingBox = NSButton(checkboxWithTitle: String(localized: "Not containing it"), target: nil, action: nil)
    private let encodingPopup = NSPopUpButton()
    private let archivesBox = NSButton(checkboxWithTitle: String(localized: "Search in archives"), target: nil, action: nil)
    /// How deep into subfolders: all, none, 1…9 levels.
    private let depthPopup = NSPopUpButton()
    private let tabs = NSTabView()
    private let advancedTab = NSTabViewItem(identifier: "advanced")

    // The Advanced tab: the date, the size, attributes.
    private let betweenBox = NSButton(checkboxWithTitle: String(localized: "Date between:"), target: nil, action: nil)
    private let fromPicker = NSDatePicker()
    private let toPicker = NSDatePicker()
    private let olderBox = NSButton(checkboxWithTitle: String(localized: "Not older than:"), target: nil, action: nil)
    private let ageField = NSTextField(string: "1")
    private let ageUnitPopup = NSPopUpButton()
    private let sizeBox = NSButton(checkboxWithTitle: String(localized: "File size:"), target: nil, action: nil)
    private let sizeComparisonPopup = NSPopUpButton()
    private let sizeField = NSTextField(string: "")
    private let sizeUnitPopup = NSPopUpButton()
    private let duplicatesBox = NSButton(checkboxWithTitle: String(localized: "Find duplicates:"), target: nil, action: nil)
    private let sameNameBox = NSButton(checkboxWithTitle: String(localized: "same name"), target: nil, action: nil)
    private let sameSizeBox = NSButton(checkboxWithTitle: String(localized: "same size"), target: nil, action: nil)
    private let sameContentsBox = NSButton(checkboxWithTitle: String(localized: "same contents"), target: nil, action: nil)
    /// Tri-state: on — the item must have it, off — must not, mixed — any.
    private let attributeBoxes: [(FileSearch.Attribute, NSButton)] = [
        (.folder, String(localized: "Folder")), (.hidden, String(localized: "Hidden")),
        (.locked, String(localized: "Locked")), (.symbolicLink, String(localized: "Symbolic link")),
        (.executable, String(localized: "Executable")),
    ].map { attribute, title in
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.allowsMixedState = true
        box.state = .mixed
        return (attribute, box)
    }

    private let startButton = NSButton(title: String(localized: "Start Search"), target: nil, action: nil)
    private let goToButton = NSButton(title: String(localized: "Go to File"), target: nil, action: nil)
    private let feedButton = NSButton(title: String(localized: "Feed to Panel"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultsTable = ResultsTableView()

    private static let ageUnits: [(title: String, component: Calendar.Component)] = [
        (String(localized: "minutes"), .minute), (String(localized: "hours"), .hour), (String(localized: "days"), .day),
        (String(localized: "weeks"), .weekOfYear), (String(localized: "months"), .month), (String(localized: "years"), .year),
    ]
    private static let sizeUnits: [(title: String, bytes: Int64)] = [
        (String(localized: "bytes"), 1), (String(localized: "KB"), 1 << 10), (String(localized: "MB"), 1 << 20),
        (String(localized: "GB"), 1 << 30),
    ]
    /// The encoding pop-up: one encoding, all of them, or bytes in hex (nil).
    private static let textEncodings: [(title: String, encodings: [TextEncoding]?)] = {
        let single: [TextEncoding] = [.utf8, .utf16, .windows1251, .dos866, .koi8r]
        return single.map { ($0.title, [$0]) } + [(String(localized: "All of them"), single), (String(localized: "Hex"), nil)]
    }()
    private static let sizeComparisons: [(title: String, comparison: FileSearch.SizeCondition.Comparison)] = [
        ("=", .equal), ("<", .less), (">", .greater),
    ]

    /// The files found, and the rows showing them: duplicates under a title per group.
    private var results: [FileSearch.Found] = []
    private var rows: [Row] = []

    private enum Row {
        case file(FileSearch.Found)
        case group(String)
    }
    private var search: FileSearch?
    private var timer: Timer?
    private var onGoTo: ((FileSearch.Found) -> Void)?
    private var onFeed: ((_ results: [URL], _ root: URL, _ title: String) -> Void)?

    /// Shows the dialog searching in `directory`; `goTo` receives the chosen result,
    /// `feed` the files found (for those found in archives, the archives).
    static func show(searchingIn directory: URL, goTo: @escaping (FileSearch.Found) -> Void,
                     feed: @escaping (_ results: [URL], _ root: URL, _ title: String) -> Void) {
        let controller = shared ?? FindFilesWindowController()
        shared = controller
        controller.onGoTo = goTo
        controller.onFeed = feed
        if controller.search == nil {
            controller.directoryField.stringValue = directory.path
        }
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.maskField)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Find Files")
        window.center()
        window.rememberFrame(as: "FindFiles")
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent() {
        startButton.target = self
        startButton.action = #selector(startOrStop(_:))
        startButton.keyEquivalent = "\r"
        goToButton.target = self
        goToButton.action = #selector(goToFile(_:))
        feedButton.target = self
        feedButton.action = #selector(feedToPanel(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = String(localized: "Found files")
        column.resizingMask = .autoresizingMask
        resultsTable.addTableColumn(column)
        resultsTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.doubleAction = #selector(goToFile(_:))
        resultsTable.onReturn = { [weak self] in self?.goToFile(nil) }
        let scrollView = NSScrollView()
        scrollView.documentView = resultsTable
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        depthPopup.addItems(withTitles: [String(localized: "All"), String(localized: "None")] + (1...9).map(String.init))
        encodingPopup.addItems(withTitles: Self.textEncodings.map(\.title))
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))
        let textOptions = NSStackView(views: [caseSensitiveBox, wholeWordsBox, textRegexBox, notContainingBox])
        textOptions.spacing = 12
        let general = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Search for:")), maskField],
            [NSGridCell.emptyContentView, nameRegexBox],
            [NSTextField(labelWithString: String(localized: "Search in:")), directoryField],
            [NSTextField(labelWithString: String(localized: "Subfolder levels:")), depthPopup],
            [NSGridCell.emptyContentView, archivesBox],
            [NSTextField(labelWithString: String(localized: "Find text:")), textField],
            [NSGridCell.emptyContentView, textOptions],
            [NSTextField(labelWithString: String(localized: "Encoding:")), encodingPopup],
        ])
        general.column(at: 0).xPlacement = .trailing
        general.rowSpacing = 6
        for index in [3, 7] {
            general.row(at: index).yPlacement = .center
        }

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = String(localized: "General")
        generalTab.view = padded(general)
        advancedTab.view = padded(advancedGrid())
        tabs.addTabViewItem(generalTab)
        tabs.addTabViewItem(advancedTab)
        updateAdvanced()

        let buttons = NSStackView(views: [statusLabel, feedButton, goToButton, startButton])
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [tabs, scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        for view in [tabs, scrollView, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        tabs.setContentHuggingPriority(.required, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack

        // Identifiers for the test harness (`set:findSize=10`).
        for (view, name) in [(maskField, "findMask"), (directoryField, "findIn"), (textField, "findText"),
                             (nameRegexBox, "findNameRegex"), (caseSensitiveBox, "findCase"),
                             (wholeWordsBox, "findWholeWords"), (textRegexBox, "findTextRegex"),
                             (notContainingBox, "findNot"), (encodingPopup, "findEncoding"), (archivesBox, "findArchives"),
                             (depthPopup, "findDepth"), (betweenBox, "findBetween"), (fromPicker, "findFrom"),
                             (toPicker, "findTo"), (olderBox, "findOlder"), (ageField, "findAge"),
                             (ageUnitPopup, "findAgeUnit"), (sizeBox, "findSizeOn"), (sizeComparisonPopup, "findSizeOp"),
                             (sizeField, "findSize"), (sizeUnitPopup, "findSizeUnit"),
                             (duplicatesBox, "findDuplicates"), (sameNameBox, "findSameName"),
                             (sameSizeBox, "findSameSize"), (sameContentsBox, "findSameContents")] as [(NSView, String)] {
            view.identifier = NSUserInterfaceItemIdentifier(name)
        }
        for (attribute, box) in attributeBoxes {
            box.identifier = NSUserInterfaceItemIdentifier("findAttr-\(attribute)")
        }
    }

    /// A tab's contents, with a margin, at the top of the tab.
    private func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func advancedGrid() -> NSView {
        for picker in [fromPicker, toPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.dateValue = Date()
        }
        ageUnitPopup.addItems(withTitles: Self.ageUnits.map(\.title))
        ageUnitPopup.selectItem(at: 2)
        sizeComparisonPopup.addItems(withTitles: Self.sizeComparisons.map(\.title))
        sizeComparisonPopup.selectItem(at: 2)
        sizeUnitPopup.addItems(withTitles: Self.sizeUnits.map(\.title))
        sizeUnitPopup.selectItem(at: 1)
        for field in [ageField, sizeField] {
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            field.alignment = .right
        }
        sameContentsBox.state = .on
        for control in [betweenBox, olderBox, sizeBox, duplicatesBox] + attributeBoxes.map(\.1) {
            control.target = self
            control.action = #selector(advancedChanged(_:))
        }

        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.spacing = 6
            return stack
        }
        let attributes = NSStackView(views: attributeBoxes.map(\.1))
        attributes.spacing = 12
        let hint = NSTextField(labelWithString: String(localized: "A check mark: has it; empty: does not have it; a dash: any."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let grid = NSGridView(views: [
            [betweenBox, row(fromPicker, NSTextField(labelWithString: String(localized: "and")), toPicker)],
            [olderBox, row(ageField, ageUnitPopup)],
            [sizeBox, row(sizeComparisonPopup, sizeField, sizeUnitPopup)],
            [NSTextField(labelWithString: String(localized: "Attributes:")), attributes],
            [NSGridCell.emptyContentView, hint],
            [duplicatesBox, row(sameNameBox, sameSizeBox, sameContentsBox)],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .leading
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        return grid
    }

    /// Bytes in hex are looked for as they are: no case, words or expressions.
    @objc private func encodingChanged(_ sender: Any?) {
        let isHex = Self.textEncodings[encodingPopup.indexOfSelectedItem].encodings == nil
        for box in [caseSensitiveBox, wholeWordsBox, textRegexBox] {
            box.isEnabled = !isHex
        }
    }

    @objc private func advancedChanged(_ sender: Any?) {
        updateAdvanced()
    }

    /// Enables the fields of the conditions turned on; the tab's title says when
    /// one is, so a condition left there is not forgotten.
    private func updateAdvanced() {
        for picker in [fromPicker, toPicker] {
            picker.isEnabled = betweenBox.state == .on
        }
        ageField.isEnabled = olderBox.state == .on
        ageUnitPopup.isEnabled = olderBox.state == .on
        for control in [sizeComparisonPopup, sizeField, sizeUnitPopup] as [NSControl] {
            control.isEnabled = sizeBox.state == .on
        }
        for box in [sameNameBox, sameSizeBox, sameContentsBox] {
            box.isEnabled = duplicatesBox.state == .on
        }
        let inUse = [betweenBox, olderBox, sizeBox, duplicatesBox].contains { $0.state == .on }
            || attributeBoxes.contains { $0.1.state != .mixed }
        advancedTab.label = inUse ? String(localized: "Advanced (in use)") : String(localized: "Advanced")
    }

    /// The query from the dialog; nil (after a message) when a number is wrong.
    private func makeQuery() -> FileSearch.Query? {
        var query = FileSearch.Query(
            root: URL(filePath: (directoryField.stringValue as NSString).expandingTildeInPath),
            masks: maskField.stringValue.isEmpty ? "*" : maskField.stringValue,
            text: textField.stringValue,
            caseSensitive: caseSensitiveBox.state == .on,
            depth: depthPopup.indexOfSelectedItem == 0 ? nil : depthPopup.indexOfSelectedItem - 1
        )
        query.nameIsRegex = nameRegexBox.state == .on
        query.inArchives = archivesBox.state == .on
        query.notContaining = notContainingBox.state == .on
        if let encodings = Self.textEncodings[encodingPopup.indexOfSelectedItem].encodings {
            query.encodings = encodings
            query.wholeWords = wholeWordsBox.state == .on
            query.textIsRegex = textRegexBox.state == .on
        } else {
            query.isHex = true
        }
        let calendar = Calendar.current
        if betweenBox.state == .on {
            let (from, to) = (min(fromPicker.dateValue, toPicker.dateValue), max(fromPicker.dateValue, toPicker.dateValue))
            query.modifiedAfter = calendar.startOfDay(for: from)
            query.modifiedBefore = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))
        }
        if olderBox.state == .on {
            guard let age = Int(ageField.stringValue.trimmingCharacters(in: .whitespaces)), age >= 0,
                  let since = calendar.date(byAdding: Self.ageUnits[ageUnitPopup.indexOfSelectedItem].component,
                                            value: -age, to: Date()) else {
                return wrongNumber(in: ageField)
            }
            query.modifiedAfter = max(query.modifiedAfter ?? since, since)
        }
        if sizeBox.state == .on {
            let unit = Self.sizeUnits[sizeUnitPopup.indexOfSelectedItem].bytes
            guard let value = Int64(sizeField.stringValue.trimmingCharacters(in: .whitespaces)), value >= 0,
                  value <= Int64.max / unit else {
                return wrongNumber(in: sizeField)
            }
            query.size = FileSearch.SizeCondition(
                comparison: Self.sizeComparisons[sizeComparisonPopup.indexOfSelectedItem].comparison,
                value: value, unit: unit)
        }
        for (attribute, box) in attributeBoxes where box.state != .mixed {
            query.attributes[attribute] = box.state == .on
        }
        if duplicatesBox.state == .on {
            let duplicates = FileSearch.Duplicates(sameName: sameNameBox.state == .on, sameSize: sameSizeBox.state == .on,
                                                   sameContents: sameContentsBox.state == .on)
            guard duplicates.sameName || duplicates.sameSize || duplicates.sameContents else {
                complain(String(localized: "Choose what the duplicates have in common."), in: sameContentsBox)
                return nil
            }
            query.duplicates = duplicates
        }
        return query
    }

    private func wrongNumber(in field: NSTextField) -> FileSearch.Query? {
        complain(String(localized: "Enter a whole number."), in: field)
        return nil
    }

    /// Shows what is wrong with the field (on its tab), the search not started.
    private func complain(_ message: String, in field: NSView) {
        if let tab = tabs.tabViewItems.first(where: { $0.view.map(field.isDescendant(of:)) ?? false }) {
            tabs.selectTabViewItem(tab)
        }
        window?.makeFirstResponder(field)
        NSSound.beep()
        statusLabel.stringValue = message
    }

    @objc private func startOrStop(_ sender: Any?) {
        if let search, !search.snapshot.isFinished {
            search.cancel()
            return
        }
        guard let query = makeQuery() else { return }
        let search: FileSearch
        do {
            search = try FileSearch(query: query)
        } catch {
            switch error {
            case .nameRegex: complain(String(localized: "The regular expression for the name is not valid."), in: maskField)
            case .textRegex: complain(String(localized: "The regular expression for the text is not valid."), in: textField)
            case .hex: complain(String(localized: "Enter the bytes in hex, as 50 4B 03 04."), in: textField)
            }
            return
        }
        self.search = search
        results = []
        rows = []
        resultsTable.reloadData()
        startButton.title = String(localized: "Stop")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Task {
            await search.run()
            refresh()
        }
    }

    private func refresh() {
        guard let search else { return }
        let state = search.snapshot
        if state.found.count != results.count {
            results = state.found
            rows = state.groups.isEmpty ? results.map(Row.file) : state.groups.flatMap { group in
                [.group(title(of: group, sameSize: search.query.duplicates.map { $0.sameSize || $0.sameContents } ?? false))]
                    + group.map(Row.file)
            }
            resultsTable.reloadData()
        }
        let summary = search.query.duplicates == nil
            ? String(localized: "\(results.count) found, \(state.scannedCount) scanned")
            : state.isFinished
            ? String(localized: "\(results.count) duplicates in \(state.groups.count) groups, \(state.scannedCount) scanned")
            : state.comparedCount > 0 ? String(localized: "comparing the contents of \(state.comparedCount) files")
            : String(localized: "\(state.scannedCount) scanned")
        if state.isFinished {
            statusLabel.stringValue = state.isCancelled ? String(localized: "Stopped: \(summary)") : String(localized: "Done: \(summary)")
            startButton.title = String(localized: "Start Search")
            timer?.invalidate()
            timer = nil
            if let first = rows.firstIndex(where: { if case .file = $0 { true } else { false } }), resultsTable.selectedRow < 0 {
                resultsTable.selectRowIndexes([first], byExtendingSelection: false)
                window?.makeFirstResponder(resultsTable)
            }
        } else {
            statusLabel.stringValue = String(localized: "Searching… \(summary)")
        }
    }

    /// Total Commander's "Feed to listbox": the results become the active panel's listing.
    @objc private func feedToPanel(_ sender: Any?) {
        guard let search, !results.isEmpty else {
            NSSound.beep()
            return
        }
        let title = String(localized: "Search results: \(search.query.masks) in \(search.query.root.path)")
        var seen = Set<URL>()
        onFeed?(results.map(\.url).filter { seen.insert($0).inserted }, search.query.root, title)
        window?.close()
    }

    @objc private func goToFile(_ sender: Any?) {
        let row = resultsTable.selectedRow
        guard rows.indices.contains(row), case .file(let found) = rows[row] else { return }
        onGoTo?(found)
        window?.close()
    }

    /// "3 files, 2 MB each" (of the same size), or "3 files" (alike by name only).
    private func title(of group: [FileSearch.Found], sameSize: Bool) -> String {
        guard sameSize, let size = try? group[0].url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return String(localized: "\(group.count) files")
        }
        return String(localized: "\(group.count) files, \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) each")
    }
}

extension FindFilesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch rows[row] {
        case .file(let found): found.path
        case .group(let title): title
        }
    }

    /// A group of duplicates is titled by a row of its own.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }
}

/// Return in the results goes to the file instead of restarting the search.
private final class ResultsTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .carriageReturn || event.specialKey == .enter {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension FindFilesWindowController: NSWindowDelegate {
    /// Closing the window (Esc) stops the search.
    func windowWillClose(_ notification: Notification) {
        search?.cancel()
    }
}
