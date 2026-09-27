import AppKit

/// Root view of the main window: two panels side by side,
/// the command line and the function key bar underneath.
final class MainViewController: NSViewController {
    private let leftPanel = PanelView()
    private let rightPanel = PanelView()
    private let splitView = NSSplitView()
    private let commandLine = CommandLineView()
    private let functionKeyBar = FunctionKeyBar()

    private var didSplitEvenly = false

    private(set) var activePanel: PanelView?

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(leftPanel)
        splitView.addArrangedSubview(rightPanel)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        for view in [splitView, commandLine, functionKeyBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            commandLine.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            commandLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            functionKeyBar.topAnchor.constraint(equalTo: commandLine.bottomAnchor),
            functionKeyBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            functionKeyBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            functionKeyBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let volumes = Volume.mounted()
        for panel in [leftPanel, rightPanel] {
            panel.show(directory: home, volumes: volumes)
            panel.pathBar.onClick = { [weak self, weak panel] in
                if let panel { self?.activate(panel) }
            }
        }
        activate(leftPanel)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didSplitEvenly {
            didSplitEvenly = true
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
    }

    func activate(_ panel: PanelView) {
        activePanel = panel
        leftPanel.isActive = panel === leftPanel
        rightPanel.isActive = panel === rightPanel
        commandLine.directory = panel.directory
    }
}
