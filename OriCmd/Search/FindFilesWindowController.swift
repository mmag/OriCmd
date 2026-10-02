import AppKit

/// Alt+F7: Total Commander's "Find Files" dialog.
final class FindFilesWindowController: NSWindowController {
    private static var shared: FindFilesWindowController?

    private let maskField = NSTextField(string: "*")
    private let directoryField = NSTextField(string: "")
    private let textField = NSTextField(string: "")
    private let caseSensitiveBox = NSButton(checkboxWithTitle: String(localized: "Case sensitive"), target: nil, action: nil)
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
    private static let sizeComparisons: [(title: String, comparison: FileSearch.SizeCondition.Comparison)] = [
        ("=", .equal), ("<", .less), (">", .greater),
    ]

    private var results: [URL] = []
    private var search: FileSearch?
    private var timer: Timer?
    private var onGoTo: ((URL) -> Void)?
    private var onFeed: ((_ results: [URL], _ root: URL, _ title: String) -> Void)?

    /// Shows the dialog searching in `directory`; `goTo` receives the chosen result.
    static func show(searchingIn directory: URL, goTo: @escaping (URL) -> Void,
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
        resultsTable.target = self
        resultsTable.doubleAction = #selector(goToFile(_:))
        resultsTable.onReturn = { [weak self] in self?.goToFile(nil) }
        let scrollView = NSScrollView()
        scrollView.documentView = resultsTable
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        depthPopup.addItems(withTitles: [String(localized: "All"), String(localized: "None")] + (1...9).map(String.init))
        let general = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Search for:")), maskField],
            [NSTextField(labelWithString: String(localized: "Search in:")), directoryField],
            [NSTextField(labelWithString: String(localized: "Subfolder levels:")), depthPopup],
            [NSTextField(labelWithString: String(localized: "Find text:")), textField],
            [NSGridCell.emptyContentView, caseSensitiveBox],
        ])
        general.column(at: 0).xPlacement = .trailing
        general.rowSpacing = 6
        general.row(at: 2).yPlacement = .center

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
                             (depthPopup, "findDepth"), (betweenBox, "findBetween"), (fromPicker, "findFrom"),
                             (toPicker, "findTo"), (olderBox, "findOlder"), (ageField, "findAge"),
                             (ageUnitPopup, "findAgeUnit"), (sizeBox, "findSizeOn"), (sizeComparisonPopup, "findSizeOp"),
                             (sizeField, "findSize"), (sizeUnitPopup, "findSizeUnit")] as [(NSView, String)] {
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
        for control in [betweenBox, olderBox, sizeBox] + attributeBoxes.map(\.1) {
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
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .leading
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        return grid
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
        let inUse = [betweenBox, olderBox, sizeBox].contains { $0.state == .on }
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
        return query
    }

    private func wrongNumber(in field: NSTextField) -> FileSearch.Query? {
        tabs.selectTabViewItem(advancedTab)
        window?.makeFirstResponder(field)
        NSSound.beep()
        statusLabel.stringValue = String(localized: "Enter a whole number.")
        return nil
    }

    @objc private func startOrStop(_ sender: Any?) {
        if let search, !search.snapshot.isFinished {
            search.cancel()
            return
        }
        guard let query = makeQuery() else { return }
        let search = FileSearch(query: query)
        self.search = search
        results = []
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
            resultsTable.reloadData()
        }
        let summary = String(localized: "\(results.count) found, \(state.scannedCount) scanned")
        if state.isFinished {
            statusLabel.stringValue = state.isCancelled ? String(localized: "Stopped: \(summary)") : String(localized: "Done: \(summary)")
            startButton.title = String(localized: "Start Search")
            timer?.invalidate()
            timer = nil
            if !results.isEmpty, resultsTable.selectedRow < 0 {
                resultsTable.selectRowIndexes([0], byExtendingSelection: false)
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
        onFeed?(results, search.query.root, title)
        window?.close()
    }

    @objc private func goToFile(_ sender: Any?) {
        let row = resultsTable.selectedRow
        guard results.indices.contains(row) else { return }
        onGoTo?(results[row])
        window?.close()
    }
}

extension FindFilesWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        results[row].path
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
