import AppKit

/// Root view of the main window: two panels side by side,
/// the command line and the function key bar underneath.
final class MainViewController: NSViewController {
    private let leftPanel: FilePanelController
    private let rightPanel: FilePanelController
    private let splitView = NSSplitView()
    private let commandLine = CommandLineView()
    private let functionKeyBar = FunctionKeyBar()

    private var didAppear = false

    private(set) var activePanel: FilePanelController

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var left = home
        var right = home
        #if DEBUG
        left = DebugAutomation.initialDirectory(left: true) ?? left
        right = DebugAutomation.initialDirectory(left: false) ?? right
        #endif
        leftPanel = FilePanelController(directory: left)
        rightPanel = FilePanelController(directory: right)
        activePanel = leftPanel
        super.init(nibName: nil, bundle: nil)
        addChild(leftPanel)
        addChild(rightPanel)
        leftPanel.delegate = self
        rightPanel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var inactivePanel: FilePanelController {
        activePanel === leftPanel ? rightPanel : leftPanel
    }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(leftPanel.view)
        splitView.addArrangedSubview(rightPanel.view)

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
        activate(leftPanel)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didAppear {
            didAppear = true
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
            activePanel.focus()
        }
    }

    private func activate(_ panel: FilePanelController) {
        activePanel = panel
        leftPanel.isActive = panel === leftPanel
        rightPanel.isActive = panel === rightPanel
        commandLine.directory = panel.directory
    }
}

extension MainViewController: FilePanelControllerDelegate {
    func filePanelDidBecomeActive(_ panel: FilePanelController) {
        activate(panel)
    }

    func filePanelSwitchPanel(_ panel: FilePanelController) {
        (panel === leftPanel ? rightPanel : leftPanel).focus()
    }

    func filePanelDidChangeDirectory(_ panel: FilePanelController) {
        if panel === activePanel {
            commandLine.directory = panel.directory
        }
    }
}
