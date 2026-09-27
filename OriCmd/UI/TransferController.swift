import AppKit

/// Runs a copy or move with a Total Commander style progress sheet
/// and "File already exists" prompts.
final class TransferController {
    private let job: TransferJob
    private let window: NSWindow
    private let progress = TransferProgress()

    private let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
                                styleMask: [.titled], backing: .buffered, defer: true)
    private let fromLabel = NSTextField(labelWithString: "")
    private let toLabel = NSTextField(labelWithString: "")
    private let fileBar = NSProgressIndicator()
    private let totalBar = NSProgressIndicator()
    private var timer: Timer?

    init(job: TransferJob, window: NSWindow) {
        self.job = job
        self.window = window
        buildSheet()
    }

    private var title: String { job.kind == .copy ? "Copying" : "Moving" }

    /// Runs the transfer and returns the sources that were fully transferred.
    /// Errors are reported to the user.
    func run() async -> [URL] {
        let source = job.sources.first?.path ?? ""
        let target = job.destination.path
        progress.update {
            $0.source = source
            $0.target = target
        }
        refresh()
        window.beginSheet(sheet, completionHandler: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let engine = TransferEngine(job: job, progress: progress) { [weak self] source, target in
            await self?.askOverwrite(source, target) ?? .cancel
        }
        var result: Result<[URL], Error>
        do {
            result = .success(try await engine.run())
        } catch {
            result = .failure(error)
        }

        timer?.invalidate()
        window.endSheet(sheet)
        switch result {
        case .success(let done):
            return done
        case .failure(let error):
            if !(error is CancellationError) {
                Prompt.error("\(title) failed", error, in: window)
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
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView()
        buttonRow.addView(cancel, in: .trailing)

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
        fromLabel.stringValue = state.source.isEmpty ? "" : "From: \(state.source)"
        toLabel.stringValue = state.target.isEmpty ? "" : "To: \(state.target)"
        fileBar.doubleValue = state.fileBytes > 0 ? Double(state.fileDoneBytes) / Double(state.fileBytes) * 100 : 0
        totalBar.doubleValue = state.totalBytes > 0 ? Double(state.doneBytes) / Double(state.totalBytes) * 100 : 0
    }

    @objc private func cancel(_ sender: Any?) {
        progress.cancel()
    }

    private func askOverwrite(_ source: URL, _ target: URL) async -> ConflictDecision {
        let alert = NSAlert()
        alert.messageText = "File already exists"
        alert.informativeText = "Overwrite:\n\(describe(target))\n\nWith:\n\(describe(source))"
        for title in ["Overwrite", "Overwrite All", "Skip", "Skip All", "Cancel"] {
            alert.addButton(withTitle: title)
        }
        let response = await alert.beginSheetModal(for: sheet)
        switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
        case 0: return .overwrite
        case 1: return .overwriteAll
        case 2: return .skip
        case 3: return .skipAll
        default: return .cancel
        }
    }

    private func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map { Int64($0).formatted(.number.grouping(.automatic)) + " bytes" } ?? ""
        let date = values?.contentModificationDate?.formatted(date: .numeric, time: .shortened) ?? ""
        return "\(url.path)\n\(size)   \(date)"
    }
}
