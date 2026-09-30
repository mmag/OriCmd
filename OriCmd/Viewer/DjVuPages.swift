import AppKit

/// DjVu pages as pictures, drawn by DjVuLibre's ddjvu when it is installed
/// (`brew install djvulibre`). ddjvu is a stranger's decoder working on a
/// stranger's file, so it runs in a sandbox that allows nothing but reading its
/// own libraries, the system's and that one file (no network, no other files, no
/// other programs), writes the picture to a pipe, and is stopped after 20 seconds.
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

    /// Page `page` (from 0) of `file`, fitted into `width`×`height` pixels (off the
    /// main thread: it waits for ddjvu).
    @concurrent
    static func render(_ file: URL, page: Int, width: Int, height: Int) async -> CGImage? {
        guard let program, width > 0, height > 0, width <= 4096, height <= 8192 else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile(program: program, file: file), program.path, "-format=ppm",
                             "-page=\(page + 1)", "-size=\(width)x\(height)", file.path, "-"]
        // DjVuLibre reads the current folder when it starts: the root, which is allowed.
        process.currentDirectoryURL = URL(filePath: "/")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let reading = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeLimit)
            if process.isRunning { process.terminate() }
        }
        let data = await reading.value
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return image(fromPPM: data, maxWidth: width, maxHeight: height)
    }

    /// Allows nothing but running ddjvu from its folder with its libraries (Homebrew,
    /// /usr/local or MacPorts keep them near), reading the system's files and `file`.
    private static func profile(program: URL, file: URL) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let prefix = program.deletingLastPathComponent().deletingLastPathComponent().path
        var readable = ["(literal \"/\")", "(literal \(quoted(file.resolvingSymlinksInPath().path)))",
                        "(literal \(quoted(file.path)))", "(subpath \"/usr/lib\")", "(subpath \"/usr/share\")",
                        "(subpath \"/System\")", "(subpath \"/private/var/db/dyld\")", "(literal \"/dev/urandom\")",
                        "(subpath \(quoted(prefix)))"]
        for root in ["/opt/homebrew", "/usr/local", "/opt/local"] where program.path.hasPrefix(root + "/") {
            readable.append("(subpath \(quoted(root)))")
        }
        return "(version 1)(deny default)(allow process-exec (literal \(quoted(program.path))))"
            + "(allow file-read* " + readable.joined(separator: " ") + ")"
            + "(allow file-read-metadata)(allow sysctl-read)"
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
        return pageWidth * CGFloat(page.height) / CGFloat(page.width)
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
            let width = Int(pageWidth * scale)
            let height = Int(self.tableView(table, heightOfRow: row) * scale)
            let file = self.file
            Task {
                let image = await DjVuPages.render(file, page: row, width: width, height: height)
                drawing.remove(row)
                if let image {
                    images[row] = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                                       height: CGFloat(image.height) / scale))
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
