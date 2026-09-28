import AppKit
import SwiftTerm

/// The command that opens a shell on a server, run in the terminal under a panel.
nonisolated struct ShellCommand: Sendable {
    /// The private escape sequence (OSC) in which the shell reports its process number.
    static let shellPIDCode = 7770

    let executable: String
    let arguments: [String]
}

/// The shell of a server under a panel: SwiftTerm's xterm emulator running
/// `ssh` over the panel's connection, below a divider that resizes it. Each
/// server tab has a terminal of its own; the pane shows the active tab's.
final class TerminalPane: NSView {
    private static let heightKey = "ServerTerminalHeight"
    static let minimumHeight: CGFloat = 60
    /// The file list keeps at least this much of the panel.
    static let minimumListHeight: CGFloat = 160

    /// Height of the pane (divider included) while shown, kept between launches.
    static var preferredHeight: CGFloat {
        get {
            let saved = AppDefaults.store.double(forKey: heightKey)
            return saved >= minimumHeight ? saved : 220
        }
        set { AppDefaults.store.set(Double(newValue), forKey: heightKey) }
    }

    static var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: Theme.panelFont.pointSize, weight: .regular)
    }

    /// The pane's height in the panel (set by the panel view).
    var heightConstraint: NSLayoutConstraint?
    /// The terminal got the keyboard focus.
    var onFocus: (() -> Void)?
    /// Return was pressed in a terminal whose session ended.
    var onReconnect: (() -> Void)?
    /// A session ended within seconds of its start (e.g. an account without a shell).
    var onEndedAtOnce: ((ShellTerminalView) -> Void)?

    private let divider = TerminalDivider()
    /// The terminal shown: the active tab's.
    private(set) var terminal: ShellTerminalView?
    private var terminalBottom: NSLayoutConstraint?
    private var keptHeight: NSLayoutConstraint?

    /// The shown terminal has a shell running (a session that ended waits for Return).
    var isRunning: Bool { terminal?.isRunning ?? false }
    var hasFocus: Bool { terminal.map { window?.firstResponder === $0 } ?? false }

    /// Hidden, the pane takes no room, while the terminal keeps its size: programs on
    /// the server are not squeezed to a single row meanwhile.
    var isCollapsed = true {
        didSet { updateTerminalHeight() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: TerminalDivider.height),
        ])
        divider.onDrag = { [weak self] delta in self?.resize(by: delta) }
        divider.onDragEnd = { [weak self] in
            if let height = self?.heightConstraint?.constant { Self.preferredHeight = height }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Starts `command` in a new terminal and shows it.
    func start(_ command: ShellCommand, over fileSystem: SFTPFileSystem) -> ShellTerminalView {
        let view = ShellTerminalView(frame: NSRect(origin: .zero, size: bounds.size))
        view.fileSystem = fileSystem
        view.font = Self.font
        // Option types characters (as Terminal.app does by default), e.g. "[" or "|" on some layouts.
        view.optionAsMetaKey = false
        view.processDelegate = self
        view.onReconnect = { [weak self] in self?.onReconnect?() }
        attach(view)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = Self.language
        view.startedAt = .now
        view.startProcess(executable: command.executable, args: command.arguments,
                          environment: environment.map { "\($0.key)=\($0.value)" })
        return view
    }

    /// Shows `terminal` (another tab's, or none); the one shown before keeps running.
    func attach(_ terminal: ShellTerminalView?) {
        guard terminal !== self.terminal else { return }
        self.terminal?.removeFromSuperview()
        self.terminal = terminal
        terminalBottom = nil
        keptHeight = nil
        guard let terminal else { return }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: divider.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        terminalBottom = terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        keptHeight = terminal.heightAnchor.constraint(equalToConstant: 0)
        updateTerminalHeight()
        applyColors()
    }

    /// Ends the session of `terminal` (the connection stays).
    func close(_ terminal: ShellTerminalView) {
        terminal.processDelegate = nil
        if terminal.process.running {
            let pid = terminal.process.shellPid
            terminal.terminate()
            // SwiftTerm stops watching the process here: it is collected in the background.
            DispatchQueue.global().async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            }
        }
        if terminal === self.terminal {
            attach(nil)
        }
    }

    /// Types `text` into the shown terminal.
    func send(_ text: String) {
        terminal?.send(txt: text)
    }

    func focus() {
        guard let terminal else { return }
        window?.makeFirstResponder(terminal)
    }

    /// The lines on the screen, for tests (the terminal's drawing is not in window snapshots).
    var screenText: String? {
        guard let screen = terminal?.getTerminal() else { return nil }
        return (0..<screen.rows).map { screen.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
            .joined(separator: "\n")
    }

    /// "ru_RU.UTF-8", as Terminal.app sets it; the server gets it through ssh's SendEnv.
    private static var language: String {
        let locale = Locale.current
        guard let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier else {
            return "en_US.UTF-8"
        }
        return "\(language)_\(region).UTF-8"
    }

    private func updateTerminalHeight() {
        guard let terminal, let terminalBottom, let keptHeight else { return }
        if isCollapsed {
            keptHeight.constant = max(terminal.frame.height, 40)
            terminalBottom.isActive = false
            keptHeight.isActive = true
        } else {
            keptHeight.isActive = false
            terminalBottom.isActive = true
        }
    }

    private func resize(by delta: CGFloat) {
        guard let heightConstraint, let panel = superview else { return }
        let maximum = max(Self.minimumHeight, panel.bounds.height - Self.minimumListHeight)
        heightConstraint.constant = min(max(heightConstraint.constant + delta, Self.minimumHeight), maximum)
    }

    // MARK: - Colors

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The panel's text colors, resolved for the current light or dark look.
    private func applyColors() {
        guard let terminal else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            terminal.nativeForegroundColor = Theme.panelText
            terminal.nativeBackgroundColor = Theme.panelBackground
            terminal.caretColor = .controlAccentColor
        }
    }
}

extension TerminalPane: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let terminal = source as? ShellTerminalView else { return }
        terminal.hasEnded = true
        terminal.feed(text: "\r\n\u{1B}[2m" + String(localized: "Session ended. Press Return to connect again.") + "\u{1B}[0m\r\n")
        if Date.now.timeIntervalSince(terminal.startedAt) < 3 {
            onEndedAtOnce?(terminal)
        }
    }
}

/// SwiftTerm's view, with the file manager's keys taken into account.
final class ShellTerminalView: LocalProcessTerminalView {
    /// Return was pressed after the session ended.
    var onReconnect: (() -> Void)?
    fileprivate(set) var hasEnded = false
    fileprivate(set) var startedAt = Date.distantPast
    /// The connection the shell runs over, asked what runs in the terminal.
    fileprivate(set) var fileSystem: SFTPFileSystem?
    /// The shell's process on the server, reported by the shell command as it starts.
    private(set) var remoteShellPID: Int?
    /// Opened by connecting rather than by ⌃`: hidden again if the server has no shell.
    var opensQuietly = false

    var isRunning: Bool { !hasEnded }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let terminal = getTerminal()
        terminal.registerOscHandler(code: ShellCommand.shellPIDCode) { [weak self] data in
            self?.remoteShellPID = Int(String(decoding: data, as: UTF8.self))
        }
        // Links from the server (OSC 8) would open any address with ⌘-click: they stay plain text.
        terminal.registerOscHandler(code: 8) { _ in }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The program running in the terminal instead of its shell ("apt", "vim"); nil
    /// while the shell waits for a command.
    func runningProgram() async -> String? {
        guard !hasEnded else { return nil }
        if let pid = remoteShellPID, let fileSystem {
            do {
                return try await fileSystem.foregroundProgram(ofShell: pid)
            } catch {
                // The server could not tell: see what is on the screen.
            }
        }
        return getTerminal().isCurrentBufferAlternate ? String(localized: "a full-screen program") : nil
    }

    /// While the terminal has the focus, keys without ⌘ are the shell's: F-keys and ⌃ or ⌥
    /// combinations would otherwise run the file manager's commands from the menu. ⌘ keys
    /// (copy, paste, …) and the keys of the terminal commands still reach the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              !event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if Command.terminalCommands.contains(where: { $0.matches(event) }) {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    /// After the session ended the keys go nowhere; Return starts a new one.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard hasEnded else {
            super.send(source: source, data: data)
            return
        }
        if data.contains(13) { onReconnect?() }
    }
}

/// The line above the terminal, dragged to resize it.
private final class TerminalDivider: NSView {
    static let height: CGFloat = 6

    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var lastY: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
    }

    /// Dragging up makes the terminal taller.
    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        onDrag?(y - lastY)
        lastY = y
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
