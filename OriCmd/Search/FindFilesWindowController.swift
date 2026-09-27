import AppKit

/// Alt+F7: Total Commander's "Find Files" dialog.
final class FindFilesWindowController: NSWindowController {
    private static var shared: FindFilesWindowController?

    private let maskField = NSTextField(string: "*")
    private let directoryField = NSTextField(string: "")
    private let textField = NSTextField(string: "")
    private let caseSensitiveBox = NSButton(checkboxWithTitle: String(localized: "Case sensitive"), target: nil, action: nil)
    private let startButton = NSButton(title: String(localized: "Start Search"), target: nil, action: nil)
    private let goToButton = NSButton(title: String(localized: "Go to File"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultsTable = ResultsTableView()

    private var results: [URL] = []
    private var search: FileSearch?
    private var timer: Timer?
    private var onGoTo: ((URL) -> Void)?

    /// Shows the dialog searching in `directory`; `goTo` receives the chosen result.
    static func show(searchingIn directory: URL, goTo: @escaping (URL) -> Void) {
        let controller = shared ?? FindFilesWindowController()
        shared = controller
        controller.onGoTo = goTo
        if controller.search == nil {
            controller.directoryField.stringValue = directory.path
        }
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.maskField)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Find Files")
        window.center()
        window.setFrameAutosaveName("FindFiles")
        super.init(window: window)
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

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Search for:")), maskField],
            [NSTextField(labelWithString: String(localized: "Search in:")), directoryField],
            [NSTextField(labelWithString: String(localized: "Find text:")), textField],
            [NSGridCell.emptyContentView, caseSensitiveBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6

        let buttons = NSStackView(views: [statusLabel, goToButton, startButton])
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [grid, scrollView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [grid, scrollView, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = stack
    }

    @objc private func startOrStop(_ sender: Any?) {
        if let search, !search.snapshot.isFinished {
            search.cancel()
            return
        }
        let root = URL(filePath: (directoryField.stringValue as NSString).expandingTildeInPath)
        let search = FileSearch(query: FileSearch.Query(
            root: root,
            masks: maskField.stringValue.isEmpty ? "*" : maskField.stringValue,
            text: textField.stringValue,
            caseSensitive: caseSensitiveBox.state == .on
        ))
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
