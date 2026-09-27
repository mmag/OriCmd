import AppKit

/// The Settings window (⌘,), the counterpart of Total Commander's Options dialog.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let fontLabel = NSTextField(labelWithString: "")
    private let quickSearchPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandLineBox = NSButton(checkboxWithTitle: String(localized: "Show command line"),
                                          target: nil, action: nil)
    private let functionKeysBox = NSButton(checkboxWithTitle: String(localized: "Show function key buttons"),
                                           target: nil, action: nil)
    private let driveButtonsBox = NSButton(checkboxWithTitle: String(localized: "Show drive buttons"),
                                           target: nil, action: nil)
    private let markedWell = NSColorWell(style: .minimal)
    private let cursorWell = NSColorWell(style: .minimal)
    private let cursorTextWell = NSColorWell(style: .minimal)
    private let alternatingBox = NSButton(checkboxWithTitle: String(localized: "Alternating row background"),
                                          target: nil, action: nil)
    private let confirmTrashBox = NSButton(checkboxWithTitle: String(localized: "Confirm moving to the Trash"),
                                           target: nil, action: nil)
    private let updatesBox = NSButton(checkboxWithTitle: String(localized: "Check for updates automatically"),
                                      target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        super.init(window: window)
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
    }

    private func buildContent() {
        let chooseFont = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseFont(_:)))
        let resetFont = NSButton(title: String(localized: "Default"), target: self, action: #selector(resetFont(_:)))
        let fontRow = NSStackView(views: [fontLabel, chooseFont, resetFont])

        quickSearchPopUp.addItems(withTitles: [
            String(localized: "Option+letters (letters go to the command line)"),
            String(localized: "Letters (Option+letters go to the command line)"),
        ])
        quickSearchPopUp.target = self
        quickSearchPopUp.action = #selector(quickSearchChanged(_:))

        for well in [markedWell, cursorWell, cursorTextWell] {
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        }
        let colors = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "marked")), markedWell,
            NSTextField(labelWithString: String(localized: "cursor")), cursorWell,
            NSTextField(labelWithString: String(localized: "cursor text")), cursorTextWell,
            NSButton(title: String(localized: "Default"), target: self, action: #selector(resetColors(_:))),
        ])
        let fileColors = NSButton(title: String(localized: "File Colors…"), target: self, action: #selector(showFileColors(_:)))

        for box in [commandLineBox, functionKeysBox, driveButtonsBox, confirmTrashBox, alternatingBox, updatesBox] {
            box.target = self
            box.action = #selector(checkboxChanged(_:))
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Panel font:")), fontRow],
            [NSTextField(labelWithString: String(localized: "Quick search:")), quickSearchPopUp],
            [NSTextField(labelWithString: String(localized: "Show:")), commandLineBox],
            [NSGridCell.emptyContentView, functionKeysBox],
            [NSGridCell.emptyContentView, driveButtonsBox],
            [NSTextField(labelWithString: String(localized: "Colors:")), colors],
            [NSGridCell.emptyContentView, alternatingBox],
            [NSGridCell.emptyContentView, fileColors],
            [NSTextField(labelWithString: String(localized: "Delete:")), confirmTrashBox],
            [NSTextField(labelWithString: String(localized: "Programs:")),
             NSButton(title: String(localized: "Internal Associations…"), target: nil,
                      action: Command.internalAssociate.selector)],
            [NSTextField(labelWithString: String(localized: "Updates:")), updatesBox],
            [NSTextField(labelWithString: String(localized: "Keyboard:")),
             NSButton(title: String(localized: "Keyboard Shortcuts…"), target: self, action: #selector(showKeys(_:)))],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    private func refresh() {
        let font = Settings.panelFont
        fontLabel.stringValue = "\(font.displayName ?? font.fontName) \(Int(font.pointSize))"
        quickSearchPopUp.selectItem(at: Settings.quickSearchMode == .optionLetters ? 0 : 1)
        commandLineBox.state = Settings.showsCommandLine ? .on : .off
        functionKeysBox.state = Settings.showsFunctionKeys ? .on : .off
        driveButtonsBox.state = Settings.showsDriveButtons ? .on : .off
        confirmTrashBox.state = Settings.confirmsMoveToTrash ? .on : .off
        updatesBox.state = Settings.checksForUpdates ? .on : .off
        alternatingBox.state = ColorSettings.alternatingRows ? .on : .off
        markedWell.color = Theme.markedText
        cursorWell.color = Theme.cursorBackground
        cursorTextWell.color = Theme.cursorText
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        switch sender {
        case markedWell: ColorSettings.markedColor = sender.color
        case cursorWell: ColorSettings.cursorColor = sender.color
        default: ColorSettings.cursorTextColor = sender.color
        }
    }

    @objc private func resetColors(_ sender: Any?) {
        ColorSettings.resetPanelColors()
        refresh()
    }

    @objc private func showFileColors(_ sender: Any?) {
        FileColorsWindowController.shared.showWindow(sender)
    }

    @objc private func showKeys(_ sender: Any?) {
        KeyBindingsWindowController.shared.showWindow(sender)
    }

    @objc private func chooseFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(Settings.panelFont, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    /// Sent by the font panel.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        Settings.panelFont = sender.convert(Settings.panelFont)
        refresh()
    }

    @objc private func resetFont(_ sender: Any?) {
        Settings.resetPanelFont()
        refresh()
    }

    @objc private func quickSearchChanged(_ sender: NSPopUpButton) {
        Settings.quickSearchMode = sender.indexOfSelectedItem == 0 ? .optionLetters : .letters
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case commandLineBox: Settings.showsCommandLine = on
        case functionKeysBox: Settings.showsFunctionKeys = on
        case driveButtonsBox: Settings.showsDriveButtons = on
        case alternatingBox: ColorSettings.alternatingRows = on
        case updatesBox: Settings.checksForUpdates = on
        default: Settings.confirmsMoveToTrash = on
        }
    }
}
