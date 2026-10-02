import AppKit
import Network
import dnssd

/// Net → Servers on the Network…: the file servers this Mac sees through Bonjour
/// (SMB, AFP, SFTP/SSH, FTP, WebDAV, NFS), as Total Commander's Network
/// Neighborhood. Choosing one fills Connect to Server with its address.
final class NetworkBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var shared: NetworkBrowserWindowController?

    /// Bonjour service types and the URL scheme each stands for.
    private static let kinds: [(type: String, scheme: String, title: String)] = [
        ("_smb._tcp", "smb", "SMB"), ("_afpovertcp._tcp", "afp", "AFP"), ("_sftp-ssh._tcp", "sftp", "SFTP"),
        ("_ssh._tcp", "sftp", "SSH"), ("_ftp._tcp", "ftp", "FTP"), ("_webdav._tcp", "http", "WebDAV"),
        ("_webdavs._tcp", "https", "WebDAV"), ("_nfs._tcp", "nfs", "NFS"),
    ]

    private struct Server: Hashable {
        let name: String
        let kind: Int
        let domain: String
    }

    private var browsers: [NWBrowser] = []
    private var servers: [Server] = []
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var onChoose: ((String) -> Void)?

    /// Shows the window; `choose` gets the address of the server chosen.
    static func show(choose: @escaping (String) -> Void) {
        let controller = shared ?? NetworkBrowserWindowController()
        shared = controller
        controller.onChoose = choose
        controller.showWindow(nil)
        controller.start()
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Servers on the Network")
        window.center()
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent() {
        for (identifier, title, width) in [("name", String(localized: "Name"), 300.0), ("kind", String(localized: "Kind"), 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connect(_:))
        table.identifier = NSUserInterfaceItemIdentifier("networkServers")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let connect = NSButton(title: String(localized: "Connect…"), target: self, action: #selector(connect(_:)))
        connect.keyEquivalent = "\r"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [statusLabel, connect])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window?.contentView = stack
    }

    /// Looks for every kind of server anew.
    private func start() {
        browsers.forEach { $0.cancel() }
        servers = []
        table.reloadData()
        statusLabel.stringValue = String(localized: "Looking for servers…")
        browsers = Self.kinds.enumerated().map { kind, entry in
            let browser = NWBrowser(for: .bonjour(type: entry.type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.update(kind: kind, results: results) }
            }
            browser.start(queue: .main)
            return browser
        }
    }

    private func update(kind: Int, results: Set<NWBrowser.Result>) {
        servers.removeAll { $0.kind == kind }
        for result in results {
            if case .service(let name, _, let domain, _) = result.endpoint {
                servers.append(Server(name: name, kind: kind, domain: domain))
            }
        }
        var seen = Set<String>()
        servers = servers.sorted { first, second in
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.kind < second.kind : order == .orderedAscending
        }.filter { seen.insert($0.name + "\u{0}" + String($0.kind)).inserted }
        table.reloadData()
        statusLabel.stringValue = String(localized: "\(servers.count) servers")
    }

    /// The address of the server chosen (its host name, from Bonjour), into
    /// Connect to Server.
    @objc private func connect(_ sender: Any?) {
        guard servers.indices.contains(table.selectedRow) else {
            NSSound.beep()
            return
        }
        let server = servers[table.selectedRow]
        let kind = Self.kinds[server.kind]
        statusLabel.stringValue = String(localized: "Finding the address of \u{201C}\(server.name)\u{201D}…")
        Task {
            guard let (host, port) = await Self.resolve(server.name, type: kind.type, domain: server.domain) else {
                statusLabel.stringValue = String(localized: "\u{201C}\(server.name)\u{201D} does not answer.")
                return
            }
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            let defaultPorts = ["smb": 445, "afp": 548, "sftp": 22, "ftp": 21, "http": 80, "https": 443, "nfs": 2049]
            let portPart = defaultPorts[kind.scheme] == Int(port) ? "" : ":\(port)"
            statusLabel.stringValue = ""
            window?.close()
            onChoose?("\(kind.scheme)://\(name)\(portPart)/")
        }
    }

    /// The host name and port of a Bonjour service (DNSServiceResolve, waited
    /// for up to 5 seconds off the main thread).
    @concurrent
    private nonisolated static func resolve(_ name: String, type: String, domain: String) async -> (String, UInt16)? {
        final class Answer {
            var value: (String, UInt16)?
        }
        let answer = Answer()
        var service: DNSServiceRef?
        let reply: DNSServiceResolveReply = { _, _, _, error, _, host, port, _, _, context in
            guard error == kDNSServiceErr_NoError, let host, let context else { return }
            Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue().value = (String(cString: host), UInt16(bigEndian: port))
        }
        guard DNSServiceResolve(&service, 0, 0, name, type, domain.isEmpty ? "local." : domain, reply,
                                Unmanaged.passUnretained(answer).toOpaque()) == kDNSServiceErr_NoError,
              let service else { return nil }
        defer { DNSServiceRefDeallocate(service) }
        var descriptor = pollfd(fd: DNSServiceRefSockFD(service), events: Int16(POLLIN), revents: 0)
        let start = Date()
        while answer.value == nil, Date().timeIntervalSince(start) < 5 {
            if poll(&descriptor, 1, 500) > 0 { DNSServiceProcessResult(service) }
        }
        return answer.value
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        servers.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        tableColumn?.identifier.rawValue == "kind" ? Self.kinds[servers[row].kind].title : servers[row].name
    }
}
