import AppKit
import Quartz
import UniformTypeIdentifiers

/// F3 viewer modelled on Total Commander's Lister. Shows text, a hex dump,
/// or a Quick Look preview (images, PDF, media, documents).
///
/// Keys: 1 text, 3 hex, 7 preview, W word wrap, N / P next / previous file,
/// F7 or ⌘F find, F3 / ⇧F3 find next / previous, Esc closes. Encodings: 8 UTF-8,
/// U UTF-16, A Windows-1251, S DOS (866), K KOI8-R; all of them in the text's
/// context menu, with Automatically. H turns syntax highlighting on and off (the
/// language follows the file's extension, see SyntaxHighlighter), F formatting of
/// JSON, XML, JavaScript, TypeScript, CSS and HTML. Excel 2003 XML, HTML pages
/// named as Excel files, CSV and TSV show as tables (7; 1 shows the text); HTML
/// and Markdown as pages (7; 1 shows the source); STL models in 3D, to be turned
/// with the mouse (7).
final class ListerWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, HandlesEscapeKey {
    enum Mode {
        case text, hex, preview, table, book, model
    }

    private nonisolated static let textLimit = 32 * 1024 * 1024
    private static let highlightingKey = "ListerSyntaxHighlighting"
    private static let formattingKey = "ListerFormatting"

    /// Syntax highlighting of program code (on unless turned off with H).
    private static var highlights: Bool {
        get { AppDefaults.store.object(forKey: highlightingKey) as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: highlightingKey) }
    }
    /// JSON, XML, program code shown laid out (off unless turned on with F).
    private static var formats: Bool {
        get { AppDefaults.store.bool(forKey: formattingKey) }
        set { AppDefaults.store.set(newValue, forKey: formattingKey) }
    }
    private nonisolated static let hexLimit = 256 * 1024
    private static var openControllers: [ListerWindowController] = []

    private var url: URL
    private let siblings: [URL]
    /// The window title's name of the file (a server or archive path instead of the local one).
    private var shownPath: String
    private var mode = Mode.text
    /// Excel 2003 XML, an HTML page named as an Excel file, CSV or TSV: shown as a
    /// table (7), by default too.
    private var tableFormat: String?
    /// FB2, EPUB…: shown as a book to read (7), by default too.
    private var bookFormat: String?
    /// STL: shown as a 3D model (7), by default too.
    private var modelFormat: String?
    /// The model's size and triangles, for the title.
    private var modelTitle = ""
    /// The book's headings, for the Contents menu.
    private var bookContents: [(title: String, location: Int, level: Int)] = []
    private var bookTitle = ""
    /// A DjVu document shows its text layer (to search it) instead of its pages.
    private var djvuShowsText = false
    private lazy var plainInset = textView.textContainerInset
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
    /// The highlighting of the text shown, cancelled when another text comes.
    private var highlighting: Task<Void, Never>?
    /// The text shown is laid out by the formatting (F), not as in the file.
    private var isFormatted = false

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
        tableFormat = Self.tableFormat(for: url)
        bookFormat = Self.bookFormat(for: url)
        modelFormat = Self.modelFormat(for: url)
        let window = ListerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.center()
        super.init(window: window)
        window.rememberFrame(as: "Lister")
        window.delegate = self

        textView.isEditable = false
        textView.delegate = self
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = textFont
        show(Self.defaultMode(for: url))
        updateTitle()
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    /// The path, and in text mode the encoding (and whether the text is formatted).
    private func updateTitle() {
        let formatted = mode == .text && isFormatted ? String(localized: "formatted") : nil
        let detail = mode == .book ? (bookTitle.isEmpty ? nil : bookTitle)
            : mode == .model ? (modelTitle.isEmpty ? nil : modelTitle)
            : mode == .text ? [encodingName, formatted].compactMap { $0 }.joined(separator: ", ")
            : mode == .table ? encodingName : nil
        window?.title = "Lister - [\(shownPath)]" + (detail.map { " \u{2014} \($0)" } ?? "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        highlighting?.cancel()
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
            case "7":
                djvuShowsText = false
                show(bookFormat != nil ? .book : modelFormat != nil ? .model : tableFormat != nil ? .table : .preview)
            case "w": toggleWrapping()
            case "n": step(1)
            case "p": step(-1)
            // Syntax highlighting is for text; a book or a table keeps its look.
            case "h" where mode == .text: toggleHighlighting()
            case "f" where mode == .text: toggleFormatting()
            case let key? where TextEncoding.allCases.contains(where: { $0.key == key }):
                choose(TextEncoding.allCases.first { $0.key == key } ?? .automatic)
            default: return false
            }
        }
        return true
    }

    private func find(_ action: NSTextFinder.Action) {
        guard mode != .preview, mode != .model else { return }
        // Tables are searched as text, DjVu pages in their text layer.
        if mode == .table { show(.text) }
        if mode == .book, bookFormat == "djvu", !djvuShowsText {
            djvuShowsText = true
            show(.book)
        }
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
        tableFormat = Self.tableFormat(for: url)
        bookFormat = Self.bookFormat(for: url)
        modelFormat = Self.modelFormat(for: url)
        djvuShowsText = false
        encodingName = nil
        show(Self.defaultMode(for: url))
    }

    /// Shows the file as text in `encoding` (from hex or the preview too), keeping
    /// the place in the text.
    private func choose(_ encoding: TextEncoding) {
        self.encoding = encoding
        if mode == .table {
            show(.table)
        } else {
            show(.text, keepingPlace: mode == .text)
        }
    }

    private func toggleHighlighting() {
        Self.highlights.toggle()
        if Self.highlights {
            highlight()
        } else {
            highlighting?.cancel()
            makePlain()
        }
    }

    /// F: JSON, XML and program code laid out for reading, or as in the file again.
    private func toggleFormatting() {
        guard Self.formatLanguage(for: url) != nil else {
            NSSound.beep()
            return
        }
        Self.formats.toggle()
        show(.text)
    }

    @objc private func formattingChosen(_ sender: NSMenuItem) {
        toggleFormatting()
    }

    /// What the formatting takes a file for, by its extension: "json", "xml", "js",
    /// "ts", "tsx", "css", "html"; nil for files it leaves as they are.
    nonisolated static func formatLanguage(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "json", "jsonc", "json5", "geojson", "webmanifest", "ipynb", "har", "jsonl", "ndjson":
            // One object a line (JSON Lines) laid out would be one long document.
            return ["jsonl", "ndjson"].contains(url.pathExtension.lowercased()) ? nil : "json"
        case "xml", "plist", "svg", "xsd", "xsl", "xslt", "rss", "atom", "xaml", "csproj", "vcxproj", "props",
             "targets", "resx", "wsdl", "kml", "gpx", "xib", "storyboard", "entitlements", "nuspec", "wxs", "fb2",
             "opf", "ncx", "dae", "config", "manifest", "xlf", "xliff", "tmx", "sitemap":
            return "xml"
        case "js", "mjs", "cjs", "jsx":
            return "js"
        case "ts", "mts", "cts":
            return "ts"
        case "tsx":
            return "tsx"
        case "css", "scss", "less":
            return "css"
        case "html", "htm", "xhtml", "shtml", "vue", "svelte":
            return "html"
        default:
            return nil
        }
    }

    /// The text without colors (new text takes the attributes where the cursor was).
    private func makePlain() {
        let plain: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: NSColor.textColor]
        textView.typingAttributes = plain
        textView.textStorage?.setAttributes(plain, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
    }

    @objc private func highlightingChosen(_ sender: NSMenuItem) {
        toggleHighlighting()
    }

    private var textFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    /// Colors the text shown when it is program code, in the background; the text
    /// stays plain if the highlighting fails or takes too long.
    private func highlight() {
        highlighting?.cancel()
        guard Self.highlights, mode == .text else { return }
        let text = textView.string
        let languages = SyntaxHighlighter.languages(for: url, start: text.prefix(4096))
        guard !languages.isEmpty else { return }
        let token = loadToken
        highlighting = Task {
            guard let ranges = await SyntaxHighlighter.highlight(text, languages: languages),
                  token == loadToken, mode == .text, Self.highlights, let storage = textView.textStorage,
                  storage.length == text.utf16.count else { return }
            // Each scope's attributes once (there are few scopes and many ranges); in
            // portions, so a long text never holds the window up.
            var attributesByScope: [String: [NSAttributedString.Key: Any]?] = [:]
            for start in stride(from: 0, to: ranges.count, by: 50_000) {
                if start > 0 {
                    await Task.yield()
                    guard token == loadToken, mode == .text, Self.highlights,
                          storage.length == text.utf16.count else { return }
                }
                storage.beginEditing()
                for (range, scope) in ranges[start..<min(start + 50_000, ranges.count)] {
                    if attributesByScope[scope] == nil {
                        attributesByScope[scope] = SyntaxTheme.attributes(for: scope, font: textFont)
                    }
                    if let attributes = attributesByScope[scope] ?? nil {
                        storage.addAttributes(attributes, range: range)
                    }
                }
                storage.endEditing()
            }
        }
    }

    @objc private func encodingChosen(_ sender: NSMenuItem) {
        guard let encoding = sender.representedObject as? TextEncoding else { return }
        choose(encoding)
    }

    /// The text's context menu starts with the encodings; a book's, with its contents.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        if mode == .book {
            guard !bookContents.isEmpty else { return menu }
            let contents = NSMenu()
            for (index, entry) in bookContents.enumerated() {
                let item = contents.addItem(withTitle: entry.title, action: #selector(contentsChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.indentationLevel = entry.level - 1
            }
            let item = NSMenuItem(title: String(localized: "Contents"), action: nil, keyEquivalent: "")
            item.submenu = contents
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }
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
        let highlighting = NSMenuItem(title: String(localized: "Syntax Highlighting"),
                                      action: #selector(highlightingChosen(_:)), keyEquivalent: "h")
        highlighting.keyEquivalentModifierMask = []
        highlighting.target = self
        highlighting.state = Self.highlights ? .on : .off
        menu.insertItem(highlighting, at: 1)
        var next = 2
        if Self.formatLanguage(for: url) != nil {
            let formatting = NSMenuItem(title: String(localized: "Format"), action: #selector(formattingChosen(_:)),
                                        keyEquivalent: "f")
            formatting.keyEquivalentModifierMask = []
            formatting.target = self
            formatting.state = Self.formats ? .on : .off
            menu.insertItem(formatting, at: next)
            next += 1
        }
        menu.insertItem(.separator(), at: next)
        return menu
    }

    // MARK: - Modes

    /// `keepingPlace`: the text shown again (in another encoding) stays about where it was.
    private func show(_ mode: Mode, keepingPlace: Bool = false) {
        guard let window else { return }
        highlighting?.cancel()
        self.mode = mode
        textView.textContainerInset = plainInset
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
            isFormatted = false
            Task {
                let content = await Self.content(of: url, hex: mode == .hex, encoding: encoding)
                guard token == loadToken else { return }
                var text = content.text
                // Laid out in the helper service (F); as in the file when it cannot be.
                if mode == .text, Self.formats, let language = Self.formatLanguage(for: url),
                   let formatted = await SyntaxHighlighter.format(text, language: language) {
                    guard token == loadToken else { return }
                    text = formatted
                    isFormatted = true
                }
                textView.string = text
                makePlain()
                if let name = content.encoding {
                    encodingName = name
                }
                updateTitle()
                highlight()
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
            if let format = Self.pageFormat(for: url) {
                showPage(format)
                return
            }
            if preview == nil {
                preview = QLPreviewView(frame: .zero, style: .normal)
            }
            guard let preview else { return }
            preview.previewItem = url as NSURL
            window.contentView = preview
        case .table:
            showTable()
        case .book:
            showBook()
        case .model:
            showModel()
        }
        window.makeFirstResponder(window.contentView)
    }

    /// An HTML file or Markdown made into a page, shown locked (see WebPreview);
    /// the text when it cannot be.
    private func showPage(_ format: String) {
        loadToken += 1
        let token = loadToken
        let url = self.url, encoding = self.encoding
        Task {
            var page: String?
            if format == "markdown" {
                let content = await Self.content(of: url, hex: false, encoding: encoding)
                guard token == loadToken else { return }
                guard let body = await SyntaxHighlighter.markdown(content.text) else { return show(.text) }
                page = MarkdownPage.html(body: body, title: url.deletingPathExtension().lastPathComponent)
            }
            guard token == loadToken, mode == .preview else { return }
            guard let view = await WebPreview.make(showing: url, page: page, encoding: encoding) else { return show(.text) }
            guard token == loadToken, mode == .preview, let window else { return }
            window.contentView = view
            window.makeFirstResponder(view.firstResponderView)
        }
    }

    /// Reads the book in the helper service (the file is a stranger's data) and
    /// shows it to read; the text or hex instead when it cannot be read.
    private func showBook() {
        textView.string = ""
        bookContents = []
        bookTitle = ""
        setWrapping(true)
        window?.contentView = scrollView
        loadToken += 1
        let token = loadToken
        let url = self.url
        guard let format = bookFormat else { return show(.text) }
        Task {
            let data = await Self.wholeFile(url, limit: SyntaxHighlighter.bookSizeLimit(for: format))
            let book = await data.asyncMap { await SyntaxHighlighter.book($0, format: format) } ?? nil
            guard token == loadToken, mode == .book else { return }
            guard let book else { return show(Self.looksLikeText(url) ? .text : .hex) }
            // DjVu: its pages as pictures when DjVuLibre draws them.
            if format == "djvu", !djvuShowsText, !book.pages.isEmpty, DjVuPages.program != nil, let window {
                let pages = DjVuPagesView(file: url, pages: book.pages)
                // Weakly: the window holds the view, the view this closure.
                weak var controller = self
                pages.onFailure = {
                    guard let controller, token == controller.loadToken, controller.mode == .book else { return }
                    controller.djvuShowsText = true
                    controller.show(.book)
                }
                window.contentView = pages
                window.makeFirstResponder(pages.firstResponderView)
                bookTitle = String(localized: "\(book.pages.count) pages")
                updateTitle()
                return
            }
            let typeset = await Task.detached { Typeset(book.typeset()) }.value
            guard token == loadToken, mode == .book else { return }
            bookTitle = [book.author, book.title].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            bookContents = typeset.contents
            updateTitle()
            fitBook()
            textView.textStorage?.setAttributedString(typeset.text)
            if format == "djvu", DjVuPages.program == nil {
                let hint = String(localized: "To see the pages themselves, install DjVuLibre (brew install djvulibre).")
                textView.textStorage?.insert(NSAttributedString(string: hint + "\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                ]), at: 0)
            }
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    /// Reads the model in the helper service (the file is a stranger's data) and shows
    /// it in 3D; the text or hex when it cannot be read.
    private func showModel() {
        textView.string = ""
        window?.contentView = scrollView
        modelTitle = ""
        loadToken += 1
        let token = loadToken
        let url = self.url
        guard let format = modelFormat else { return show(.text) }
        Task {
            let data = await Self.wholeFile(url, limit: SyntaxHighlighter.meshSizeLimit)
            let model = await data.asyncMap { await SyntaxHighlighter.mesh($0, format: format) } ?? nil
            guard token == loadToken, mode == .model, let window else { return }
            guard let model else { return show(Self.looksLikeText(url) ? .text : .hex) }
            let view = ModelView(model: model)
            window.contentView = view
            window.makeFirstResponder(view.firstResponderView)
            // 12.5 × 40 × 3, or 6E38 for sizes no one would read in digits.
            let dimensions = [model.size.x, model.size.y, model.size.z].map { value in
                value >= 1e7 || (value > 0 && value < 1e-3)
                    ? value.formatted(.number.notation(.scientific).precision(.significantDigits(1...3)))
                    : value.formatted(.number.precision(.significantDigits(1...4)))
            }.joined(separator: " × ")
            modelTitle = dimensions + ", " + String(localized: "triangles: \(model.triangleCount)")
            updateTitle()
        }
    }

    /// A column of about 720 points in the middle of the window.
    private func fitBook() {
        guard mode == .book else { return }
        let margin = max(24, (scrollView.contentSize.width - 720) / 2)
        textView.textContainerInset = NSSize(width: margin, height: 24)
    }

    func windowDidResize(_ notification: Notification) {
        fitBook()
    }

    @objc private func contentsChosen(_ sender: NSMenuItem) {
        guard bookContents.indices.contains(sender.tag) else { return }
        let location = bookContents[sender.tag].location
        // The heading at the top (only the text up to it is laid out).
        let range = NSRange(location: location, length: 0)
        textView.scrollRangeToVisible(range)
        if let window = textView.window {
            let onScreen = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let rect = textView.convert(window.convertFromScreen(onScreen), from: nil)
            textView.scroll(NSPoint(x: 0, y: max(rect.minY - 24, 0)))
        }
    }

    /// Reads the table in the helper service (the file is a stranger's data) and
    /// shows it; the text instead when the file is too big or holds no table.
    private func showTable() {
        textView.string = ""
        window?.contentView = scrollView
        loadToken += 1
        let token = loadToken
        let url = self.url
        let encoding = self.encoding
        guard let format = tableFormat else { return show(.text) }
        Task {
            let loaded = await Self.tableText(of: url, encoding: encoding)
            guard token == loadToken else { return }
            guard let loaded else { return show(.text) }
            encodingName = loaded.encoding
            updateTitle()
            let table = await SyntaxHighlighter.tables(loaded.text, format: format)
            guard token == loadToken, mode == .table, let window else { return }
            guard let table else { return show(.text) }
            let grid = TableGridView(table: table)
            window.contentView = grid
            window.makeFirstResponder(grid.firstResponderView)
        }
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
        if bookFormat(for: url) != nil { return .book }
        if modelFormat(for: url) != nil { return .model }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if let type, [.image, .pdf, .rtf, .rtfd, .font].contains(where: type.conforms(to:)) {
            return .preview
        }
        let text = looksLikeText(url)
        // Video and sound by the contents too: TypeScript shares .ts with MPEG transport
        // streams (and .mts, .cts with camera video).
        if let type, !text, type.conforms(to: .audiovisualContent) {
            return .preview
        }
        if let type, !text, [.presentation, .spreadsheet].contains(where: type.conforms(to:))
            || officePrefixes.contains(where: type.identifier.hasPrefix) {
            return .preview
        }
        if text, tableFormat(for: url) != nil {
            return .table
        }
        if text, pageFormat(for: url) != nil {
            return .preview
        }
        return text ? .text : .hex
    }

    /// HTML and Markdown files are shown as pages (7, and at first): "html" or "markdown".
    static func pageFormat(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "html", "htm", "xhtml", "shtml": "html"
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtext": "markdown"
        default: nil
        }
    }

    /// Excel 2003 XML by its start: the mso-application instruction before the root
    /// element, or a root Workbook in the spreadsheet namespace (not a mention of it
    /// somewhere in the text).
    private static func isSpreadsheetML(_ start: String) -> Bool {
        var rest = Substring(start)
        while let open = rest.firstIndex(of: "<") {
            let tag = rest[open...].prefix { $0 != ">" }
            if tag.hasPrefix("<?") {
                if tag.contains("progid=\"excel.sheet\"") { return true }
            } else if !tag.hasPrefix("<!") {
                let name = tag.dropFirst().prefix { !$0.isWhitespace && $0 != "/" }
                return (name == "workbook" || name.hasSuffix(":workbook"))
                    && tag.contains("urn:schemas-microsoft-com:office:spreadsheet")
            }
            rest = rest[tag.endIndex...]
        }
        return false
    }

    /// The 3D model format of `url` by its name, if it is one.
    static func modelFormat(for url: URL) -> String? {
        url.pathExtension.lowercased() == "stl" ? "stl" : nil
    }

    /// The book format of `url` by its name, if it is one.
    static func bookFormat(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".fb2.zip") { return "fb2.zip" }
        switch url.pathExtension.lowercased() {
        case "fb2": return "fb2"
        case "epub": return "epub"
        case "mobi", "azw", "azw3", "prc": return "mobi"
        case "djvu", "djv": return "djvu"
        case "pdb":
            // Palm databases share the name with Visual Studio's debug files: by the header.
            let type = String(decoding: head(of: url, limit: 68).data.dropFirst(60), as: UTF8.self)
            return type == "BOOKMOBI" || type == "TEXtREAd" ? "mobi" : nil
        default: return nil
        }
    }

    /// The table format of `url`, if it has one: CSV and TSV by the extension, Excel
    /// 2003 XML by its text whatever the name, an HTML page named as an Excel file
    /// (what many programs export).
    static func tableFormat(for url: URL) -> String? {
        let head = head(of: url, limit: 8192).data
        guard TextDecoding.looksLikeText(head) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "csv" { return "csv" }
        if ext == "tsv" || ext == "tab" { return "tsv" }
        let start = TextDecoding.string(from: head).lowercased()
        if isSpreadsheetML(start) { return "spreadsheetml" }
        if ["xls", "xlsx", "xlsm", "xlsb", "ods"].contains(ext),
           ["<table", "<html", "<!doctype html"].contains(where: start.contains) {
            return "html"
        }
        return nil
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

    /// The whole file, if it is no larger than `limit`.
    @concurrent
    private nonisolated static func wholeFile(_ url: URL, limit: Int) async -> Data? {
        let (data, size) = head(of: url, limit: limit)
        return size <= data.count ? data : nil
    }

    /// The whole file as text for the table view (none past the text limit).
    @concurrent
    private nonisolated static func tableText(of url: URL, encoding: TextEncoding) async
        -> (text: String, encoding: String)? {
        let (data, size) = head(of: url, limit: textLimit)
        guard size <= data.count else { return nil }
        let (text, name) = TextDecoding.decode(data, as: encoding)
        return (text, name)
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
