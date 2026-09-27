import AppKit

/// One of the two file panels, laid out top to bottom like in Total Commander:
/// volume selector with free space, path bar, file list, status line.
final class PanelView: NSView {
    let volumeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let freeSpaceLabel = NSTextField(labelWithString: "")
    let rootButton = NSButton(title: "/", target: nil, action: nil)
    let parentButton = NSButton(title: "..", target: nil, action: nil)
    let pathBar = PathBar()
    let scrollView = NSScrollView()
    let statusLabel = NSTextField(labelWithString: "")

    var onVolumeSelected: ((Volume) -> Void)?
    var onGoToRoot: (() -> Void)?
    var onGoToParent: (() -> Void)?

    var isActive = false {
        didSet { pathBar.isActive = isActive }
    }

    private(set) var directory = URL(filePath: "/")
    private var volumes: [Volume] = []

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

        statusLabel.font = Theme.chromeFont
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let views: [NSView] = [volumeButton, freeSpaceLabel, rootButton, parentButton, pathBar, scrollView, statusLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            volumeButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            volumeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            volumeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            freeSpaceLabel.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            freeSpaceLabel.leadingAnchor.constraint(equalTo: volumeButton.trailingAnchor, constant: 6),
            freeSpaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootButton.leadingAnchor, constant: -6),

            parentButton.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            parentButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            parentButton.widthAnchor.constraint(equalToConstant: 24),
            rootButton.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
            rootButton.trailingAnchor.constraint(equalTo: parentButton.leadingAnchor, constant: -2),
            rootButton.widthAnchor.constraint(equalToConstant: 24),

            pathBar.topAnchor.constraint(equalTo: volumeButton.bottomAnchor, constant: 3),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Updates the header for `directory`: path, current volume and free space.
    func show(directory: URL, volumes: [Volume]) {
        self.directory = directory
        self.volumes = volumes
        pathBar.path = directory.path

        volumeButton.removeAllItems()
        volumeButton.addItems(withTitles: volumes.map(\.name))
        if let current = Volume.containing(directory, in: volumes),
           let index = volumes.firstIndex(of: current) {
            volumeButton.selectItem(at: index)
        }
        freeSpaceLabel.stringValue = VolumeSpace(for: directory)?.summary ?? ""
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
