import AppKit

/// The current path line above a file list, e.g. "/Users/me/*.*".
/// Highlighted when its panel is the active one; a click makes it editable.
final class PathBar: NSView {
    var path = "" {
        didSet { needsDisplay = true }
    }

    var isActive = false {
        didSet { needsDisplay = true }
    }

    /// Appends the file mask ("*.*", or the panel filter), as Total Commander does.
    var showsMask = true {
        didSet { needsDisplay = true }
    }

    var mask = "*.*" {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?
    /// The text to edit when the bar is clicked (the path without the mask).
    var editableText: (() -> String)?
    /// Enter in the field: go there.
    var onCommit: ((String) -> Void)?
    /// The names Tab completes the typed text to (full texts, "/" after folders).
    var completions: ((String) async -> [String])?

    private var field: NSTextField?
    /// Tab cycling: the text before it began, its candidates and the one shown.
    private var cycle: (base: String, candidates: [String], index: Int)?

    var isEditing: Bool { field != nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? Theme.activeHeaderBackground : Theme.inactiveHeaderBackground).setFill()
        bounds.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.panelFont,
            .foregroundColor: isActive ? Theme.activeHeaderText : Theme.inactiveHeaderText,
            .paragraphStyle: paragraph,
        ]
        let text = showsMask ? (path.hasSuffix("/") ? path : path + "/") + mask : path
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
            in: NSRect(x: 4, y: (bounds.height - height) / 2, width: bounds.width - 8, height: height),
            withAttributes: attributes
        )
    }

    /// A click turns the path into a field (Enter goes there, Esc cancels, Tab completes).
    override func mouseDown(with event: NSEvent) {
        onClick?()
        beginEditing()
    }

    func beginEditing() {
        guard field == nil, let text = editableText?() else { return }
        let field = NSTextField(string: text)
        field.font = Theme.panelFont
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.frame = bounds
        field.autoresizingMask = [.width, .height]
        addSubview(field)
        self.field = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    /// Ends editing, going to the typed text on commit.
    func endEditing(commit: Bool) {
        guard let field else { return }
        let text = field.stringValue
        self.field = nil
        cycle = nil
        field.delegate = nil
        field.removeFromSuperview()
        needsDisplay = true
        if commit {
            onCommit?(text)
        } else {
            onClick?()
        }
    }

    /// Tab: completes to what the candidates have in common, then goes through them.
    private func complete(backwards: Bool) {
        guard let field, let completions else { return }
        if var cycle, cycle.candidates.contains(field.stringValue) {
            cycle.index = (cycle.index + (backwards ? -1 : 1) + cycle.candidates.count) % cycle.candidates.count
            self.cycle = cycle
            show(cycle.candidates[cycle.index], in: field)
            return
        }
        let typed = field.stringValue
        Task {
            let candidates = await completions(typed)
            guard self.field === field, field.stringValue == typed, !candidates.isEmpty else {
                if candidates.isEmpty { NSSound.beep() }
                return
            }
            let common = Self.commonPrefix(of: candidates)
            if candidates.count == 1 || common.count > typed.count {
                cycle = candidates.count > 1 ? (typed, candidates, -1) : nil
                show(candidates.count == 1 ? candidates[0] : common, in: field)
            } else {
                cycle = (typed, candidates, backwards ? candidates.count - 1 : 0)
                show(candidates[cycle!.index], in: field)
            }
        }
    }

    private func show(_ text: String, in field: NSTextField) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    /// The longest start the texts share, ignoring letter case (as the file system does).
    private static func commonPrefix(of texts: [String]) -> String {
        guard var prefix = texts.first else { return "" }
        for text in texts.dropFirst() {
            while !text.lowercased().hasPrefix(prefix.lowercased()) { prefix.removeLast() }
        }
        return prefix
    }
}

extension PathBar: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true)
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
        case #selector(NSResponder.insertTab(_:)):
            complete(backwards: false)
        case #selector(NSResponder.insertBacktab(_:)):
            complete(backwards: true)
        default:
            return false
        }
        return true
    }

    /// Clicking elsewhere cancels.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard field != nil else { return }
        endEditing(commit: false)
    }
}
