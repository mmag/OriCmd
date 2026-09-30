import AppKit

/// DjVu pages as pictures, drawn by DjVuLibre's ddjvu when it is installed
/// (`brew install djvulibre`). ddjvu is a stranger's decoder working on a
/// stranger's file, so it runs in a sandbox that allows nothing but reading its
/// own libraries and the system's (no network, no files, no other programs); the
/// document comes on its standard input, opened by OriCmd, the picture goes to a
/// pipe and is taken only up to the size asked for, and ddjvu is killed after 20
/// seconds.
nonisolated enum DjVuPages {
    /// ddjvu, where Homebrew, MacPorts or a manual install put it.
    static let program: URL? = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["ORICMD_DDJVU"] {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
        }
        #endif
        return ["/opt/homebrew/bin/ddjvu", "/usr/local/bin/ddjvu", "/opt/local/bin/ddjvu"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0).resolvingSymlinksInPath() }
    }()

    private static let timeLimit: Duration = .seconds(20)
    /// The largest picture asked for; taller pages are drawn smaller.
    static let maxWidth = 4096, maxHeight = 8192

    /// Page `page` (from 0) of `file`, fitted into `width`×`height` pixels (off the
    /// main thread: it waits for ddjvu).
    @concurrent
    static func render(_ file: URL, page: Int, width: Int, height: Int) async -> CGImage? {
        guard let program, width > 0, height > 0, width <= maxWidth, height <= maxHeight,
              let document = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? document.close() }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile(program: program), program.path, "-format=ppm",
                             "-page=\(page + 1)", "-size=\(width)x\(height)", "-", "-"]
        // DjVuLibre reads the current folder when it starts: the root, which is allowed.
        process.currentDirectoryURL = URL(filePath: "/")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = document
        // The header and the pixels of the largest picture that would be taken.
        let reading = Reading(limit: 64 + (width + 2) * (height + 2) * 3)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reading.finish(.output)
            } else if !reading.append(chunk), process.isRunning {
                // More than a picture that size: no picture at all.
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.terminationHandler = { _ in reading.finish(.process) }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // Asked to stop after the time limit, then made to.
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeLimit)
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        await reading.wait()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0, let data = reading.data else { return nil }
        return image(fromPPM: data, maxWidth: width, maxHeight: height)
    }

    /// ddjvu's output, taken up to a limit, and the ends waited for (the output
    /// closed, the process gone), without holding a thread.
    private final class Reading: @unchecked Sendable {
        enum End { case output, process }
        private let lock = NSLock()
        private let limit: Int
        private var buffer = Data()
        private var overflowed = false
        private var ended: Set<End> = []
        private var waiting: CheckedContinuation<Void, Never>?

        init(limit: Int) {
            self.limit = limit
        }

        /// Whether the chunk was taken (false once past the limit).
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                guard !overflowed, buffer.count + chunk.count <= limit else {
                    overflowed = true
                    buffer = Data()
                    return false
                }
                buffer.append(chunk)
                return true
            }
        }

        var data: Data? { lock.withLock { overflowed ? nil : buffer } }

        func finish(_ end: End) {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                ended.insert(end)
                guard ended.count == 2 else { return nil }
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let done = lock.withLock {
                    if ended.count == 2 { return true }
                    waiting = continuation
                    return false
                }
                if done { continuation.resume() }
            }
        }
    }

    /// Allows nothing but running ddjvu with its libraries (in its own folder's
    /// lib/, or Homebrew's, /usr/local's or MacPorts' installed packages) and
    /// reading the system's files; no file literal is needed: the document comes
    /// on the standard input.
    private static func profile(program: URL) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let prefix = program.deletingLastPathComponent().deletingLastPathComponent()
        var readable = ["(literal \"/\")", "(literal \(quoted(program.path)))", "(subpath \"/usr/lib\")",
                        "(subpath \"/usr/share\")", "(subpath \"/System\")", "(subpath \"/private/var/db/dyld\")",
                        "(literal \"/dev/urandom\")", "(subpath \(quoted(prefix.appending(path: "lib").path)))"]
        for root in ["/opt/homebrew", "/usr/local", "/opt/local"] where program.path.hasPrefix(root + "/") {
            for folder in ["Cellar", "opt", "lib"] {
                readable.append("(subpath \(quoted(root + "/" + folder)))")
            }
        }
        return "(version 1)(deny default)(allow process-exec (literal \(quoted(program.path))))"
            + "(allow file-read* " + readable.joined(separator: " ") + ")"
    }

    /// A binary PPM (P6, 8 bits) no larger than asked, as a picture; nil otherwise.
    static func image(fromPPM data: Data, maxWidth: Int, maxHeight: Int) -> CGImage? {
        let bytes = [UInt8](data.prefix(64))
        var fields: [Int] = []
        var index = 2
        guard bytes.count > 2, bytes[0] == 0x50, bytes[1] == 0x36 else { return nil }
        while fields.count < 3, index < bytes.count {
            while index < bytes.count, bytes[index] == 0x20 || (0x09...0x0D).contains(bytes[index]) { index += 1 }
            var value = 0, digits = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]), digits < 6 {
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
                digits += 1
            }
            guard digits > 0 else { return nil }
            fields.append(value)
        }
        guard fields.count == 3, index < bytes.count else { return nil }
        let (width, height, maximum) = (fields[0], fields[1], fields[2])
        let start = index + 1
        guard width > 0, height > 0, width <= maxWidth + 2, height <= maxHeight + 2, maximum == 255,
              data.count == start + width * height * 3,
              let provider = CGDataProvider(data: data.dropFirst(start) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The pages of a DjVu document one under another, fitted to the width, drawn as
/// they come into view (two at a time, the last few kept).
final class DjVuPagesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let file: URL
    private let pages: [(width: Int, height: Int, dpi: Int)]
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private var images: [Int: NSImage] = [:]
    private var order: [Int] = []
    private var drawing: Set<Int> = []
    private var queue: [Int] = []
    /// Whether a page was drawn yet; if the first one tried fails, `onFailure` says so.
    private var drewPage = false
    private var reportedFailure = false
    var onFailure: (() -> Void)?
    /// Pages drawn so far (for the regression checks).
    private(set) var drawnCount = 0
    private static let kept = 24
    private static let gap: CGFloat = 12

    init(file: URL, pages: [(width: Int, height: Int, dpi: Int)]) {
        self.file = file
        self.pages = pages
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .underPageBackgroundColor
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: Self.gap)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification,
                                               object: scrollView)
        scrollView.postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The pages take the keys (arrows, page up and down).
    var firstResponderView: NSView { table }

    /// The width pages are shown at: the view's, at most about a screen page wide.
    private var pageWidth: CGFloat { max(min(scrollView.contentSize.width - 32, 900), 100) }

    @objc private func resized() {
        // Other sizes: drawn again when seen.
        images = [:]
        order = []
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<pages.count))
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        pages.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let page = pages[row]
        guard page.width > 0, page.height > 0 else { return pageWidth * 1.4 }
        // A crafted size (1 × 65535) would make a row millions of points tall.
        return pageWidth * min(max(CGFloat(page.height) / CGFloat(page.width), 0.05), 20)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("page"), owner: self) as? PageCell
            ?? PageCell()
        cell.identifier = NSUserInterfaceItemIdentifier("page")
        cell.show(images[row], number: row + 1, of: pages.count, width: pageWidth)
        if images[row] == nil { draw(row) }
        return cell
    }

    private func draw(_ row: Int) {
        guard !drawing.contains(row), !queue.contains(row) else { return }
        queue.append(row)
        drawNext()
    }

    private func drawNext() {
        while drawing.count < 2, !queue.isEmpty {
            let row = queue.removeLast()
            // Only what is still in view.
            guard table.rows(in: table.visibleRect).contains(row) || table.visibleRect.isEmpty else { continue }
            drawing.insert(row)
            let scale = window?.backingScaleFactor ?? 2
            var width = Int(pageWidth * scale)
            var height = Int(self.tableView(table, heightOfRow: row) * scale)
            // Tall pages are drawn smaller (and shown enlarged).
            if height > DjVuPages.maxHeight {
                width = max(width * DjVuPages.maxHeight / height, 1)
                height = DjVuPages.maxHeight
            }
            width = min(width, DjVuPages.maxWidth)
            let file = self.file
            Task {
                let image = await DjVuPages.render(file, page: row, width: width, height: height)
                drawing.remove(row)
                if image == nil, !drewPage, !reportedFailure {
                    // ddjvu cannot draw this document: its text instead.
                    reportedFailure = true
                    onFailure?()
                    return
                }
                if let image {
                    drewPage = true
                    drawnCount += 1
                    images[row] = NSImage(cgImage: image, size: NSSize(width: pageWidth,
                                                                       height: self.tableView(table, heightOfRow: row)))
                    order.append(row)
                    if order.count > Self.kept { images[order.removeFirst()] = nil }
                    table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
                drawNext()
            }
        }
    }
}

/// A page's picture, centered, with its number under it.
private final class PageCell: NSView {
    private let picture = NSImageView()
    private let number = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.white.cgColor
        number.font = .systemFont(ofSize: 10)
        number.textColor = .secondaryLabelColor
        number.alignment = .center
        for view in [picture, number] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.bottomAnchor.constraint(equalTo: bottomAnchor),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            number.centerXAnchor.constraint(equalTo: centerXAnchor),
            number.topAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var widthConstraint: NSLayoutConstraint?

    func show(_ image: NSImage?, number page: Int, of count: Int, width: CGFloat) {
        picture.image = image
        widthConstraint?.isActive = false
        widthConstraint = picture.widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
        number.stringValue = "\(page) / \(count)"
    }
}
