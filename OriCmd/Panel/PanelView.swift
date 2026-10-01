import AppKit

/// One of the two file panels, laid out top to bottom like in Total Commander:
/// volume selector with free space, path bar, file list, status line, and the
/// terminal of a server when one is connected.
final class PanelView: NSView {
    let driveBar = DriveBar()
    let volumeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let freeSpaceLabel = NSTextField(labelWithString: "")
    /// Spins while a slow folder is being read.
    let loadingIndicator = NSProgressIndicator()
    let rootButton = NSButton(title: "/", target: nil, action: nil)
    let parentButton = NSButton(title: "..", target: nil, action: nil)
    let tabBar = FolderTabBar()
    let pathBar = PathBar()
    let headerView = FileListHeaderView()
    let scrollView = NSScrollView()
    let listView = FileListView()
    let statusLabel = NSTextField(labelWithString: "")
    /// Quick search box shown over the status line.
    let quickSearchField = NSTextField()
    let terminalPane = TerminalPane()

    var onVolumeSelected: ((Volume) -> Void)?
    var onGoToRoot: (() -> Void)?
    var onGoToParent: (() -> Void)?

    var isActive = false {
        didSet {
            pathBar.isActive = isActive
            listView.isActive = isActive
        }
    }

    private var volumes: [Volume] = []
    private var tabBarHeight: NSLayoutConstraint!
    private var headerHeight: NSLayoutConstraint!
    private var driveBarHeight: NSLayoutConstraint!
    private var terminalHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        volumeButton.controlSize = .small
        volumeButton.font = Theme.chromeFont
        volumeButton.target = self
        volumeButton.action = #selector(volumeChanged(_:))

        freeSpaceLabel.font = Theme.chromeFont
        freeSpaceLabel.textColor = .secondaryLabelColor
        freeSpaceLabel.lineBreakMode = .byTruncatingTail
        freeSpaceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, action) in [(rootButton, #selector(rootClicked(_:))), (parentButton, #selector(parentClicked(_:)))] {
            button.controlSize = .small
            button.font = Theme.chromeFont
            button.bezelStyle = .smallSquare
            button.target = self
            button.action = action
        }

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.panelBackground
        scrollView.documentView = listView

        statusLabel.font = Theme.chromeFont
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        quickSearchField.font = Theme.chromeFont
        quickSearchField.placeholderString = String(localized: "Quick search")
        quickSearchField.isHidden = true

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false

        let views: [NSView] = [driveBar, loadingIndicator, volumeButton, freeSpaceLabel, rootButton, parentButton, tabBar, pathBar, headerView,
                               scrollView, statusLabel, quickSearchField, terminalPane]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        headerHeight = headerView.heightAnchor.constraint(equalToConstant: headerView.intrinsicContentSize.height)
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        driveBarHeight = driveBar.heightAnchor.constraint(equalToConstant: DriveBar.height)
        tabBar.isHidden = true
        terminalHeight = terminalPane.heightAnchor.constraint(equalToConstant: 0)
        // A smaller window takes room from the terminal rather than from the file list.
        terminalHeight.priority = .init(998)
        let listMinimum = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: TerminalPane.minimumListHeight)
        listMinimum.priority = .init(999)
        terminalPane.heightConstraint = terminalHeight
        terminalPane.isHidden = true
        NSLayoutConstraint.activate([
            driveBar.topAnchor.constraint(equalTo: topAnchor),
            driveBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            driveBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            driveBarHeight,

            volumeButton.topAnchor.constraint(equalTo: driveBar.bottomAnchor, constant: 3),
            volumeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            volumeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            freeSpaceLabel.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            freeSpaceLabel.leadingAnchor.constraint(equalTo: volumeButton.trailingAnchor, constant: 6),
            freeSpaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootButton.leadingAnchor, constant: -6),

            parentButton.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            parentButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            parentButton.widthAnchor.constraint(equalToConstant: 24),
            loadingIndicator.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            loadingIndicator.trailingAnchor.constraint(equalTo: rootButton.leadingAnchor, constant: -6),
            rootButton.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            rootButton.trailingAnchor.constraint(equalTo: parentButton.leadingAnchor, constant: -2),
            rootButton.widthAnchor.constraint(equalToConstant: 24),

            tabBar.topAnchor.constraint(equalTo: volumeButton.bottomAnchor, constant: 3),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeight,

            pathBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            headerView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            listMinimum,

            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            statusLabel.bottomAnchor.constraint(equalTo: terminalPane.topAnchor, constant: -3),

            terminalPane.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalPane.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalPane.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalHeight,

            quickSearchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            quickSearchField.widthAnchor.constraint(equalToConstant: 200),
            quickSearchField.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Full view shows column headers and scrolls vertically; Brief view has
    /// no headers and scrolls horizontally.
    func setViewMode(_ mode: FileListView.ViewMode) {
        headerView.isHidden = mode != .full
        headerHeight.constant = mode == .full ? headerView.intrinsicContentSize.height : 0
        scrollView.hasVerticalScroller = mode != .brief
        scrollView.hasHorizontalScroller = mode == .brief
        listView.viewMode = mode
    }

    /// Shows the terminal under the status line at its last height, leaving the
    /// file list some room.
    func setTerminalVisible(_ visible: Bool) {
        terminalPane.isHidden = !visible
        terminalPane.isCollapsed = !visible
        let maximum = max(TerminalPane.minimumHeight, bounds.height - TerminalPane.minimumListHeight)
        terminalHeight.constant = visible ? min(TerminalPane.preferredHeight, maximum) : 0
    }

    var isTerminalVisible: Bool { !terminalPane.isHidden }

    func setDriveBarVisible(_ visible: Bool) {
        driveBar.isHidden = !visible
        driveBarHeight.constant = visible ? DriveBar.height : 0
    }

    /// Shows the folder tabs (the bar is hidden when `visible` is false).
    func setTabs(_ titles: [String], identifiers: [UUID], selected: Int, visible: Bool) {
        tabBar.titles = titles
        tabBar.identifiers = identifiers
        tabBar.selectedIndex = selected
        tabBar.isHidden = !visible
        tabBarHeight.constant = visible ? FolderTabBar.height : 0
    }

    /// Updates the header for `directory`: path, current volume and free space.
    func setLoading(_ loading: Bool) {
        if loading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    /// `freeSpace` is computed here when not given (it can be slow on network volumes).
    func show(directory: URL, volumes: [Volume], freeSpace: String? = nil) {
        if volumes != self.volumes || driveBar.drives.isEmpty {
            driveBar.drives = DriveBar.drives(for: volumes)
        }
        self.volumes = volumes
        driveBar.currentPath = directory.path

        volumeButton.removeAllItems()
        volumeButton.addItems(withTitles: volumes.map(\.name))
        if let current = Volume.containing(directory, in: volumes),
           let index = volumes.firstIndex(of: current) {
            volumeButton.selectItem(at: index)
        }
        freeSpaceLabel.stringValue = freeSpace ?? VolumeSpace(for: directory)?.summary ?? ""
    }

    @objc private func volumeChanged(_ sender: NSPopUpButton) {
        guard volumes.indices.contains(sender.indexOfSelectedItem) else { return }
        onVolumeSelected?(volumes[sender.indexOfSelectedItem])
    }

    @objc private func rootClicked(_ sender: Any?) {
        onGoToRoot?()
    }

    @objc private func parentClicked(_ sender: Any?) {
        onGoToParent?()
    }
}
