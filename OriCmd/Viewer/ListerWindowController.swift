import AppKit
import Quartz
import UniformTypeIdentifiers

/// F3 viewer modelled on Total Commander's Lister. Shows text, a hex dump,
/// or a Quick Look preview (images, PDF, media, documents).
///
/// Keys: 1 text, 3 hex, 7 preview, W word wrap, N / P next / previous file,
/// F7 or ⌘F find, F3 / ⇧F3 find next / previous, Esc closes. Encodings: 8 UTF-8,
/// U UTF-16, A Windows-1251, S DOS (866), K KOI8-R; all of them in the text's
/// context menu, with Automatically.
final class ListerWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, HandlesEscapeKey {
    enum Mode {
        case text, hex, preview
    }

    private nonisolated static let textLimit = 32 * 1024 * 1024
    private nonisolated static let hexLimit = 256 * 1024
    private static var openControllers: [ListerWindowController] = []

    private var url: URL
    private let siblings: [URL]
    /// The window title's name of the file (a server or archive path instead of the local one).
    private var shownPath: String
    private var mode = Mode.text
    /// Chosen by the user; kept for the next and previous files.
    private var encoding = TextEncoding.automatic
    /// The encoding the text is shown in (the one told, when automatic).
    private var encodingName: String?
    private var wrapsLines = true
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private var preview: QLPreviewView?
    /// Only the latest requested text or hex view is shown.
    private var loadToken = 0

    /// Shows `url`; N / P step through `siblings` (the other files of its folder).
    /// `title` replaces the path in the window title (for files from servers and archives).
    static func show(_ url: URL, siblings: [URL] = [], title: String? = nil) {
        let controller = ListerWindowController(url: url, siblings: siblings)
        if let title {
            controller.shownPath = title
            controller.updateTitle()
        }
        openControllers.append(controller)
        controller.showWindow(nil)
    }

    private init(url: URL, siblings: [URL]) {
        self.url = url
        self.siblings = siblings
        shownPath = url.path
        let window = ListerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.center()
        window.rememberFrame(as: "Lister")
        super.init(window: window)
        window.delegate = self

        textView.isEditable = false
        textView.delegate = self
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        show(Self.defaultMode(for: url))
        updateTitle()
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    /// The path, and in text mode the encoding.
    private func updateTitle() {
        let encoding = mode == .text ? encodingName.map { " \u{2014} \($0)" } ?? "" : ""
        window?.title = "Lister - [\(shownPath)]" + encoding
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
            case let key? where TextEncoding.allCases.contains(where: { $0.key == key }):
                choose(TextEncoding.allCases.first { $0.key == key } ?? .automatic)
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
        shownPath = url.path
        encodingName = nil
        show(Self.defaultMode(for: url))
    }

    /// Shows the file as text in `encoding` (from hex or the preview too), keeping
    /// the place in the text.
    private func choose(_ encoding: TextEncoding) {
        self.encoding = encoding
        show(.text, keepingPlace: mode == .text)
    }

    @objc private func encodingChosen(_ sender: NSMenuItem) {
        guard let encoding = sender.representedObject as? TextEncoding else { return }
        choose(encoding)
    }

    /// The text's context menu starts with the encodings.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let encodings = NSMenu()
        for encoding in TextEncoding.allCases {
            let item = encodings.addItem(withTitle: encoding.title, action: #selector(encodingChosen(_:)),
                                         keyEquivalent: encoding.key ?? "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = encoding
            item.state = encoding == self.encoding ? .on : .off
            if encoding == .automatic {
                encodings.addItem(.separator())
            }
        }
        let item = NSMenuItem(title: String(localized: "Encoding"), action: nil, keyEquivalent: "")
        item.submenu = encodings
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    // MARK: - Modes

    /// `keepingPlace`: the text shown again (in another encoding) stays about where it was.
    private func show(_ mode: Mode, keepingPlace: Bool = false) {
        guard let window else { return }
        self.mode = mode
        updateTitle()
        switch mode {
        case .text, .hex:
            // The share of the text above the view, to scroll to after reloading.
            let length = textView.string.utf16.count
            let place = keepingPlace && length > 0
                ? Double(textView.characterIndexForInsertion(at: textView.visibleRect.origin)) / Double(length) : nil
            // Up to 32 MB of text: read and decoded off the main thread.
            textView.string = ""
            setWrapping(mode == .text ? wrapsLines : false)
            window.contentView = scrollView
            loadToken += 1
            let token = loadToken
            let url = self.url
            let encoding = self.encoding
            Task {
                let content = await Self.content(of: url, hex: mode == .hex, encoding: encoding)
                guard token == loadToken else { return }
                textView.string = content.text
                if let name = content.encoding {
                    encodingName = name
                    updateTitle()
                }
                if let place {
                    // The same place at the top of the view again.
                    let range = NSRange(location: Int(place * Double(textView.string.utf16.count)), length: 0)
                    textView.scrollRangeToVisible(range)
                    if let window = textView.window {
                        let onScreen = textView.firstRect(forCharacterRange: range, actualRange: nil)
                        let rect = textView.convert(window.convertFromScreen(onScreen), from: nil)
                        textView.scroll(NSPoint(x: 0, y: rect.minY))
                    }
                }
            }
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
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if let type, [.image, .pdf, .audiovisualContent, .rtf, .rtfd, .font].contains(where: type.conforms(to:)) {
            return .preview
        }
        let text = looksLikeText(url)
        if let type, !text, [.presentation, .spreadsheet].contains(where: type.conforms(to:))
            || officePrefixes.contains(where: type.identifier.hasPrefix) {
            return .preview
        }
        return text ? .text : .hex
    }

    /// Office documents (Word, Excel, PowerPoint in all their variants, Pages, Numbers,
    /// Keynote, OpenDocument) are shown as Quick Look shows them: as text or hex only
    /// their insides would be seen. They are zip or OLE files; text files that share
    /// their extensions (.key PEM keys, .template, hunspell .dic) stay text.
    private static let officePrefixes = [
        "com.microsoft.word.", "com.microsoft.excel.", "com.microsoft.powerpoint.",
        "org.openxmlformats.", "com.apple.iwork.", "org.oasis-open.opendocument.",
    ]

    // MARK: - Content

    /// The text or hex dump, and for text the name of the encoding used.
    @concurrent
    private nonisolated static func content(of url: URL, hex: Bool, encoding: TextEncoding) async
        -> (text: String, encoding: String?) {
        hex ? (hexDump(of: url), nil) : text(of: url, encoding: encoding)
    }

    private nonisolated static func head(of url: URL, limit: Int) -> (data: Data, size: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: 0)
        return ((try? handle.read(upToCount: limit)) ?? Data(), size)
    }

    private static func looksLikeText(_ url: URL) -> Bool {
        TextDecoding.looksLikeText(head(of: url, limit: 8192).data)
    }

    private nonisolated static func text(of url: URL, encoding: TextEncoding) -> (text: String, encoding: String) {
        let (data, size) = head(of: url, limit: textLimit)
        var (result, name) = TextDecoding.decode(data, as: encoding, truncated: size > data.count)
        if size > data.count {
            result += "\n\n" + truncationNote(shown: data.count, of: size)
        }
        return (result, name)
    }

    private nonisolated static func truncationNote(shown: Int, of size: Int) -> String {
        let shownText = shown.formatted()
        let sizeText = size.formatted()
        return String(localized: "[… showing the first \(shownText) of \(sizeText) bytes]")
    }

    private nonisolated static func hexDump(of url: URL) -> String {
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
