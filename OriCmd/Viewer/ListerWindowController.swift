import AppKit
import Quartz
import UniformTypeIdentifiers

/// F3 viewer modelled on Total Commander's Lister. Shows text, a hex dump,
/// or a Quick Look preview (images, PDF, media, documents).
///
/// Keys: 1 text, 3 hex, 7 preview, W word wrap, N / P next / previous file,
/// F7 or ⌘F find, F3 / ⇧F3 find next / previous, Esc closes.
final class ListerWindowController: NSWindowController, NSWindowDelegate {
    enum Mode {
        case text, hex, preview
    }

    private static let textLimit = 32 * 1024 * 1024
    private static let hexLimit = 256 * 1024
    private static var openControllers: [ListerWindowController] = []

    private var url: URL
    private let siblings: [URL]
    private var mode = Mode.text
    private var wrapsLines = true
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private var preview: QLPreviewView?

    /// Shows `url`; N / P step through `siblings` (the other files of its folder).
    /// `title` replaces the path in the window title (for files from servers and archives).
    static func show(_ url: URL, siblings: [URL] = [], title: String? = nil) {
        let controller = ListerWindowController(url: url, siblings: siblings)
        if let title {
            controller.window?.title = "Lister - [\(title)]"
        }
        openControllers.append(controller)
        controller.showWindow(nil)
    }

    private init(url: URL, siblings: [URL]) {
        self.url = url
        self.siblings = siblings
        let window = ListerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Lister - [\(url.path)]"
        window.center()
        window.setFrameAutosaveName("Lister")
        super.init(window: window)
        window.delegate = self

        textView.isEditable = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        show(Self.defaultMode(for: url))
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        preview?.close()
        Self.openControllers.removeAll { $0 === self }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.shortcutCharacters == "f" {
            find(.showFindInterface)
            return true
        }
        switch (event.specialKey, modifiers) {
        case (.f7?, []): find(.showFindInterface)
        case (.f3?, []): find(.nextMatch)
        case (.f3?, [.shift]): find(.previousMatch)
        default:
            // Plain keys only when the find bar is not being typed into.
            guard modifiers.isEmpty || modifiers == .shift, !(window?.firstResponder is NSTextView
                  && window?.firstResponder !== textView) else { return false }
            switch event.shortcutCharacters {
            case "\u{1b}": window?.close()
            case "1": show(.text)
            case "3": show(.hex)
            case "7": show(.preview)
            case "w": toggleWrapping()
            case "n": step(1)
            case "p": step(-1)
            default: return false
            }
        }
        return true
    }

    private func find(_ action: NSTextFinder.Action) {
        guard mode != .preview else { return }
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    private func toggleWrapping() {
        guard mode == .text else { return }
        wrapsLines.toggle()
        setWrapping(wrapsLines)
    }

    /// N / P: shows the next or previous file of the folder in this window.
    private func step(_ offset: Int) {
        guard let index = siblings.firstIndex(of: url), siblings.indices.contains(index + offset) else {
            NSSound.beep()
            return
        }
        url = siblings[index + offset]
        window?.title = "Lister - [\(url.path)]"
        show(Self.defaultMode(for: url))
    }

    // MARK: - Modes

    private func show(_ mode: Mode) {
        guard let window else { return }
        self.mode = mode
        switch mode {
        case .text:
            textView.string = Self.text(of: url)
            setWrapping(wrapsLines)
            window.contentView = scrollView
        case .hex:
            textView.string = Self.hexDump(of: url)
            setWrapping(false)
            window.contentView = scrollView
        case .preview:
            if preview == nil {
                preview = QLPreviewView(frame: .zero, style: .normal)
            }
            guard let preview else { return }
            preview.previewItem = url as NSURL
            window.contentView = preview
        }
        window.makeFirstResponder(window.contentView)
    }

    private func setWrapping(_ wraps: Bool) {
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        let width = wraps ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = wraps ? [.width] : []
    }

    static func defaultMode(for url: URL) -> Mode {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           [.image, .pdf, .audiovisualContent, .rtf, .rtfd, .presentation, .spreadsheet, .font]
            .contains(where: type.conforms(to:)) {
            return .preview
        }
        return looksLikeText(url) ? .text : .hex
    }

    // MARK: - Content

    private static func head(of url: URL, limit: Int) -> (data: Data, size: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: 0)
        return ((try? handle.read(upToCount: limit)) ?? Data(), size)
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        !head(of: url, limit: 8192).data.contains(0)
    }

    private static func text(of url: URL) -> String {
        let (data, size) = head(of: url, limit: textLimit)
        var result = TextDecoding.string(from: data)
        if size > data.count {
            result += "\n\n" + truncationNote(shown: data.count, of: size)
        }
        return result
    }

    private static func truncationNote(shown: Int, of size: Int) -> String {
        let shownText = shown.formatted()
        let sizeText = size.formatted()
        return String(localized: "[… showing the first \(shownText) of \(sizeText) bytes]")
    }

    private static func hexDump(of url: URL) -> String {
        let (data, size) = head(of: url, limit: hexLimit)
        var lines: [String] = []
        lines.reserveCapacity(data.count / 16 + 2)
        let bytes = [UInt8](data)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = String(row.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X", offset) + "  " + padded + "  " + ascii)
        }
        if size > data.count {
            lines.append("\n" + truncationNote(shown: data.count, of: size))
        }
        return lines.joined(separator: "\n")
    }
}

/// Lets the Lister handle its single-key commands before the text view sees them.
private final class ListerWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
