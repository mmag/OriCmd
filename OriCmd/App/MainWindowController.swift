import AppKit

final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "MainWindow"
    private let buttonBar = ButtonBar()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OriCmd"
        window.toolbar = buttonBar.toolbar
        window.toolbarStyle = .unifiedCompact
        // Buttons start at the left, like Total Commander's button bar.
        window.titleVisibility = .hidden
        window.contentViewController = MainViewController()
        window.minSize = NSSize(width: 640, height: 400)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
