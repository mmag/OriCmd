import AppKit

final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "MainWindow"
    private let buttonBar = ButtonBar()

    init() {
        let window = MainWindow(
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
        // Applications dropped on the toolbar become buttons.
        window.registerForDraggedTypes([.fileURL])
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        if !window.rememberFrame(as: Self.frameAutosaveName) {
            window.center()
        }
        window.onDropApplications = { [weak self] urls in self?.buttonBar.addApplications(urls) }
    }

    /// Puts applications on the button bar (dropped there, or "Add to Button Bar").
    func addApplications(_ urls: [URL]) {
        buttonBar.addApplications(urls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
