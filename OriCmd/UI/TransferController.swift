import AppKit

/// Runs a long file operation (copy, move, pack, unpack) with a Total Commander
/// style progress sheet and "File already exists" prompts.
final class TransferController {
    typealias Work = @Sendable (TransferProgress, @escaping TransferEngine.ConflictHandler) async throws -> [URL]

    private let title: String
    private let failureTitle: String
    private let window: NSWindow
    private let progress = TransferProgress()

    private let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
                                styleMask: [.titled], backing: .buffered, defer: true)
    private let fromLabel = NSTextField(labelWithString: "")
    private let toLabel = NSTextField(labelWithString: "")
    private let fileBar = NSProgressIndicator()
    private let totalBar = NSProgressIndicator()
    private var timer: Timer?
    private let backgroundButton = NSButton(title: String(localized: "Background"), target: nil, action: nil)
    /// After "Background" the progress is a separate window and the main window stays usable.
    private var isInBackground = false

    /// Queued operations start in their own window right away.
    var startsInBackground = false

    init(title: String, failureTitle: String, window: NSWindow) {
        self.title = title
        self.failureTitle = failureTitle
        self.window = window
        buildSheet()
    }

    /// Copies or moves files; returns the sources that were fully transferred.
    static func run(_ job: TransferJob, in window: NSWindow, inBackground: Bool = false) async -> [URL] {
        let controller = job.kind == .copy
            ? TransferController(title: String(localized: "Copying"), failureTitle: String(localized: "Copying failed"),
                                 window: window)
            : TransferController(title: String(localized: "Moving"), failureTitle: String(localized: "Moving failed"),
                                 window: window)
        controller.startsInBackground = inBackground
        return await controller.run(source: job.sources.first?.path ?? "", target: job.destination.path) {
            progress, resolveConflict in
            try await TransferEngine(job: job, progress: progress, resolveConflict: resolveConflict).run()
        }
    }

    /// Shows the progress sheet while `work` runs; returns its result.
    /// Errors are reported to the user; cancellation returns an empty list.
    func run(source: String, target: String, _ work: @escaping Work) async -> [URL] {
        progress.update {
            $0.source = source
            $0.target = target
        }
        refresh()
        if startsInBackground {
            showInOwnWindow()
        } else {
            window.beginSheet(sheet, completionHandler: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let resolveConflict: TransferEngine.ConflictHandler = { [weak self] source, target in
            await self?.askOverwrite(source, target) ?? .cancel
        }
        var result: Result<[URL], Error>
        do {
            result = .success(try await work(progress, resolveConflict))
        } catch {
            result = .failure(error)
        }

        timer?.invalidate()
        if isInBackground {
            sheet.orderOut(nil)
        } else {
            window.endSheet(sheet)
        }
        switch result {
        case .success(let done):
            return done
        case .failure(let error):
            if !(error is CancellationError) {
                Prompt.error(failureTitle, error, in: window)
            }
            return []
        }
    }

    private func buildSheet() {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        for label in [fromLabel, toLabel] {
            label.font = Theme.chromeFont
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for bar in [fileBar, totalBar] {
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 100
        }
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"

        backgroundButton.target = self
        backgroundButton.action = #selector(moveToBackground(_:))
        let buttonRow = NSStackView()
        buttonRow.addView(backgroundButton, in: .trailing)
        buttonRow.addView(cancel, in: .trailing)
        sheet.hidesOnDeactivate = false

        let stack = NSStackView(views: [heading, fromLabel, toLabel, fileBar, totalBar, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView = stack
        for view in [fromLabel, toLabel, fileBar, totalBar, buttonRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
    }

    private func refresh() {
        let state = progress.snapshot
        for bar in [fileBar, totalBar] where bar.isIndeterminate != (state.totalBytes == 0) {
            bar.isIndeterminate = state.totalBytes == 0
            if bar.isIndeterminate { bar.startAnimation(nil) }
        }
        fromLabel.stringValue = state.source.isEmpty ? "" : String(localized: "From: \(state.source)")
        toLabel.stringValue = state.target.isEmpty ? "" : String(localized: "To: \(state.target)")
        fileBar.doubleValue = state.fileBytes > 0 ? Double(state.fileDoneBytes) / Double(state.fileBytes) * 100 : 0
        totalBar.doubleValue = state.totalBytes > 0 ? Double(state.doneBytes) / Double(state.totalBytes) * 100 : 0
    }

    /// Total Commander's "Background": the operation continues in its own small
    /// window while the panels can be used.
    @objc private func moveToBackground(_ sender: Any?) {
        guard !isInBackground else { return }
        window.endSheet(sheet)
        showInOwnWindow()
    }

    private func showInOwnWindow() {
        isInBackground = true
        backgroundButton.isHidden = true
        let waiting = TransferQueue.shared.waitingCount
        sheet.title = waiting > 0 ? String(localized: "\(title) (\(waiting) more queued)") : title
        sheet.center()
        // The progress window shows up, but typing stays in the panels.
        sheet.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func cancel(_ sender: Any?) {
        progress.cancel()
    }

    private func askOverwrite(_ source: URL, _ target: URL) async -> ConflictDecision {
        let alert = NSAlert()
        alert.messageText = String(localized: "File already exists")
        alert.informativeText = String(localized: "Overwrite:\n\(describe(target))\n\nWith:\n\(describe(source))")
        for title in [String(localized: "Overwrite"), String(localized: "Overwrite All"), String(localized: "Skip"),
                      String(localized: "Skip All"), String(localized: "Overwrite All Older"), String(localized: "Cancel")] {
            alert.addButton(withTitle: title)
        }
        let response = await alert.beginSheetModal(for: sheet)
        switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
        case 0: return .overwrite
        case 1: return .overwriteAll
        case 2: return .skip
        case 3: return .skipAll
        case 4: return .overwriteAllOlder
        default: return .cancel
        }
    }

    private func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map { String(localized: "\(Int64($0).formatted(.number.grouping(.automatic))) bytes") } ?? ""
        let date = values?.contentModificationDate?.formatted(date: .numeric, time: .shortened) ?? ""
        return "\(url.path)\n\(size)   \(date)"
    }
}
