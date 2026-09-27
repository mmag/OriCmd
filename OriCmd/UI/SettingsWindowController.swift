import AppKit

/// The Settings window (⌘,), the counterpart of Total Commander's Options
/// dialog: one pane per topic, chosen in the toolbar as in the system apps.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabs = NSTabViewController()

    private init() {
        tabs.tabStyle = .toolbar
        let panes: [(NSViewController, String, String)] = [
            (GeneralPane(), String(localized: "General"), "gearshape"),
            (PanelsPane(), String(localized: "Panels"), "rectangle.split.2x1"),
            (ColorsPane(), String(localized: "Colors"), "paintpalette"),
            (OperationsPane(), String(localized: "Operations"), "doc.on.doc"),
            (KeyboardPane(), String(localized: "Keyboard"), "keyboard"),
        ]
        for (pane, title, symbol) in panes {
            pane.title = title
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        super.init(window: window)
        #if DEBUG
        if let tab = ProcessInfo.processInfo.environment["ORICMD_SETTINGS_TAB"].flatMap(Int.init),
           tabs.tabViewItems.indices.contains(tab) {
            tabs.selectedTabViewItemIndex = tab
        }
        #endif
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// MARK: - Building blocks

/// A pane: sections with bold titles, labelled controls and grey explanations.
class SettingsPane: NSViewController {
    private var rows: [[NSView]] = []
    private var fullWidthRows: [Int] = []
    private var titleRows: [Int] = []
    /// Rows whose control has no text baseline (color wells): centered instead.
    private var centeredRows: [Int] = []
    static let noteWidth: CGFloat = 400

    override func loadView() {
        build()
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for index in fullWidthRows {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: index, length: 1))
            grid.row(at: index).cell(at: 0).xPlacement = .leading
        }
        for index in titleRows where index > 0 {
            grid.row(at: index).topPadding = 14
        }
        for index in centeredRows {
            grid.row(at: index).rowAlignment = .none
            grid.row(at: index).yPlacement = .center
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
        ])
        self.view = view
        preferredContentSize = view.fittingSize
    }

    /// Adds the rows of the pane.
    func build() {}

    func section(_ title: String) {
        if !rows.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            fullWidthRows.append(rows.count)
            rows.append([separator, NSGridCell.emptyContentView])
        }
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleRows.append(rows.count)
        fullWidthRows.append(rows.count)
        rows.append([label, NSGridCell.emptyContentView])
    }

    func row(_ label: String?, _ views: NSView...) {
        let content: NSView = views.count == 1 ? views[0] : {
            let stack = NSStackView(views: views)
            stack.spacing = 8
            return stack
        }()
        if content is NSColorWell {
            centeredRows.append(rows.count)
        }
        rows.append([label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView, content])
    }

    func note(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.noteWidth
        label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.noteWidth).isActive = true
        rows.append([NSGridCell.emptyContentView, label])
    }

    func fullWidth(_ view: NSView) {
        fullWidthRows.append(rows.count)
        rows.append([view, NSGridCell.emptyContentView])
    }

    func checkbox(_ title: String, _ value: Bool, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = value ? .on : .off
        return box
    }

    func button(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSButton {
        NSButton(title: title, target: target ?? self, action: action)
    }
}

// MARK: - General

private final class GeneralPane: SettingsPane {
    private let languagePopUp = NSPopUpButton()
    private let restartButton = NSButton()
    private let restartNote = NSTextField(labelWithString: "")

    override func build() {
        section(String(localized: "Language"))
        let running = Settings.runningLanguage == .russian ? "Русский" : "English"
        languagePopUp.addItems(withTitles: [String(localized: "As in the system (\(running))"), "English", "Русский"])
        languagePopUp.selectItem(at: Settings.Language.allCases.firstIndex(of: Settings.language) ?? 0)
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged(_:))
        row(String(localized: "Interface language:"), languagePopUp)
        restartButton.title = String(localized: "Restart Now")
        restartButton.target = self
        restartButton.action = #selector(restart(_:))
        restartNote.stringValue = String(localized: "OriCmd shows the new language after a restart.")
        restartNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        restartNote.textColor = .secondaryLabelColor
        row(nil, restartNote, restartButton)
        updateRestart()

        section(String(localized: "Updates"))
        row(nil, checkbox(String(localized: "Check for updates automatically"), Settings.checksForUpdates,
                          #selector(updatesChanged(_:))))
        note(String(localized: "Once a day OriCmd looks for a new release on GitHub and offers to install it."))
        row(nil, button(String(localized: "Check Now"), #selector(AppDelegate.checkForUpdates(_:)), target: NSApp.delegate),
            NSTextField(labelWithString: String(localized: "Version \(Updater.currentVersion)")))
    }

    /// The restart button shows while the chosen language differs from the running one.
    private func updateRestart() {
        let chosen = Settings.language
        let effective: Settings.Language = chosen == .system ? systemLanguage : chosen
        let differs = effective != Settings.runningLanguage
        restartButton.isHidden = !differs
        restartNote.isHidden = !differs
    }

    private var systemLanguage: Settings.Language {
        let preferred = Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                      forPreferences: UserDefaults(suiteName: UserDefaults.globalDomain)?
                                                        .stringArray(forKey: "AppleLanguages"))
        return preferred.first?.hasPrefix("ru") == true ? .russian : .english
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        Settings.language = Settings.Language.allCases[sender.indexOfSelectedItem]
        updateRestart()
    }

    @objc private func restart(_ sender: Any?) {
        Relaunch.now()
    }

    @objc private func updatesChanged(_ sender: NSButton) {
        Settings.checksForUpdates = sender.state == .on
    }
}

// MARK: - Panels

private final class PanelsPane: SettingsPane {
    private let fontLabel = NSTextField(labelWithString: "")

    override func build() {
        section(String(localized: "Preview"))
        fullWidth(PanelPreview())

        section(String(localized: "Font"))
        row(String(localized: "Panel font:"), fontLabel, button(String(localized: "Choose…"), #selector(chooseFont(_:))),
            button(String(localized: "Default"), #selector(resetFont(_:))))
        updateFontLabel()

        section(String(localized: "Window"))
        row(String(localized: "Show:"), checkbox(String(localized: "Command line"), Settings.showsCommandLine,
                                                 #selector(commandLineChanged(_:))))
        row(nil, checkbox(String(localized: "Function key buttons (F3 View … F8 Delete)"), Settings.showsFunctionKeys,
                          #selector(functionKeysChanged(_:))))
        row(nil, checkbox(String(localized: "Drive buttons"), Settings.showsDriveButtons, #selector(driveButtonsChanged(_:))))
        row(String(localized: "Button bar:"), button(String(localized: "Customize Toolbar…"), #selector(customizeToolbar(_:))))
        note(String(localized: "Optional columns (kind, created, dimensions, duration, tags) are chosen by right-clicking a panel's column headers."))
    }

    private func updateFontLabel() {
        let font = Settings.panelFont
        fontLabel.stringValue = "\(font.displayName ?? font.fontName), \(Int(font.pointSize)) pt"
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
        updateFontLabel()
    }

    @objc private func resetFont(_ sender: Any?) {
        Settings.resetPanelFont()
        updateFontLabel()
    }

    @objc private func commandLineChanged(_ sender: NSButton) { Settings.showsCommandLine = sender.state == .on }
    @objc private func functionKeysChanged(_ sender: NSButton) { Settings.showsFunctionKeys = sender.state == .on }
    @objc private func driveButtonsChanged(_ sender: NSButton) { Settings.showsDriveButtons = sender.state == .on }

    @objc private func customizeToolbar(_ sender: Any?) {
        NSApp.windows.first { $0.windowController is MainWindowController }?.runToolbarCustomizationPalette(sender)
    }
}

// MARK: - Colors

private final class ColorsPane: SettingsPane {
    private let markedWell = NSColorWell(style: .default)
    private let cursorWell = NSColorWell(style: .default)
    private let cursorTextWell = NSColorWell(style: .default)
    private let alternatingBox = NSButton()

    override func build() {
        section(String(localized: "Preview"))
        fullWidth(PanelPreview())

        section(String(localized: "Panel colors"))
        for well in [markedWell, cursorWell, cursorTextWell] {
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        row(String(localized: "Marked files:"), markedWell)
        row(String(localized: "Cursor:"), cursorWell)
        row(String(localized: "Cursor text:"), cursorTextWell)
        alternatingBox.setButtonType(.switch)
        alternatingBox.title = String(localized: "Alternating row background")
        alternatingBox.target = self
        alternatingBox.action = #selector(alternatingChanged(_:))
        row(nil, alternatingBox)
        row(nil, button(String(localized: "Default Colors"), #selector(resetColors(_:))))

        section(String(localized: "File colors"))
        row(nil, button(String(localized: "File Colors…"), #selector(showFileColors(_:))))
        note(String(localized: "Colors by file mask — archives, pictures, scripts — like \u{201C}Define colors by file type\u{201D} in Total Commander."))
        refresh()
    }

    private func refresh() {
        markedWell.color = Theme.markedText
        cursorWell.color = Theme.cursorBackground
        cursorTextWell.color = Theme.cursorText
        alternatingBox.state = ColorSettings.alternatingRows ? .on : .off
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        switch sender {
        case markedWell: ColorSettings.markedColor = sender.color
        case cursorWell: ColorSettings.cursorColor = sender.color
        default: ColorSettings.cursorTextColor = sender.color
        }
    }

    @objc private func alternatingChanged(_ sender: NSButton) {
        ColorSettings.alternatingRows = sender.state == .on
    }

    @objc private func resetColors(_ sender: Any?) {
        ColorSettings.resetPanelColors()
        refresh()
    }

    @objc private func showFileColors(_ sender: Any?) {
        FileColorsWindowController.shared.showWindow(sender)
    }
}

// MARK: - Operations

private final class OperationsPane: SettingsPane {
    private let overwritePopUp = NSPopUpButton()

    override func build() {
        section(String(localized: "Copy and move (F5 / F6)"))
        for mode in OverwriteMode.allCases {
            overwritePopUp.addItem(withTitle: mode.title)
        }
        overwritePopUp.selectItem(at: Settings.copyOverwriteMode.rawValue - 1)
        overwritePopUp.target = self
        overwritePopUp.action = #selector(overwriteChanged(_:))
        row(String(localized: "If a file exists:"), overwritePopUp)
        row(nil, checkbox(String(localized: "Verify copied files"), Settings.copyVerifies, #selector(verifyChanged(_:))))
        row(nil, checkbox(String(localized: "Copy extended attributes and ACLs"), Settings.copyAttributes,
                          #selector(attributesChanged(_:))))
        row(nil, checkbox(String(localized: "Skip all which cannot be opened for reading"), Settings.copySkipsUnreadable,
                          #selector(skipUnreadableChanged(_:))))
        row(nil, checkbox(String(localized: "Overwrite/delete locked files"), Settings.copyOverwritesLocked,
                          #selector(overwriteLockedChanged(_:))))
        note(String(localized: "These are the defaults of the copy dialog; its \u{201C}Options >>\u{201D} change them for one operation."))

        section(String(localized: "Delete"))
        row(nil, checkbox(String(localized: "Confirm moving to the Trash"), Settings.confirmsMoveToTrash,
                          #selector(confirmTrashChanged(_:))))
        note(String(localized: "Shift+F8 deletes permanently and always asks."))

        section(String(localized: "Programs"))
        row(String(localized: "Files:"), button(String(localized: "Internal Associations…"),
                                                Command.internalAssociate.selector, target: NSApp.delegate))
        note(String(localized: "Which program opens, views (F3) or edits (F4) files of a given type."))
        row(String(localized: "Start menu:"), button(String(localized: "Change Start Menu…"),
                                                     #selector(AppDelegate.showStartMenuEditor(_:)), target: NSApp.delegate))
        note(String(localized: "Your own commands with %P, %N, %S parameters, in the menu and on the button bar."))
    }

    @objc private func overwriteChanged(_ sender: NSPopUpButton) {
        Settings.copyOverwriteMode = OverwriteMode(rawValue: sender.indexOfSelectedItem + 1) ?? .ask
    }

    @objc private func verifyChanged(_ sender: NSButton) { Settings.copyVerifies = sender.state == .on }
    @objc private func attributesChanged(_ sender: NSButton) { Settings.copyAttributes = sender.state == .on }
    @objc private func skipUnreadableChanged(_ sender: NSButton) { Settings.copySkipsUnreadable = sender.state == .on }
    @objc private func overwriteLockedChanged(_ sender: NSButton) { Settings.copyOverwritesLocked = sender.state == .on }
    @objc private func confirmTrashChanged(_ sender: NSButton) { Settings.confirmsMoveToTrash = sender.state == .on }
}

// MARK: - Keyboard

private final class KeyboardPane: SettingsPane {
    override func build() {
        section(String(localized: "Quick search"))
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: [
            String(localized: "Option+letters (letters go to the command line)"),
            String(localized: "Letters (Option+letters go to the command line)"),
        ])
        popUp.selectItem(at: Settings.quickSearchMode == .optionLetters ? 0 : 1)
        popUp.target = self
        popUp.action = #selector(quickSearchChanged(_:))
        row(String(localized: "Search file names with:"), popUp)
        note(String(localized: "As in Total Commander, Alt (Option) with letters jumps to a file; plain letters type into the command line."))

        section(String(localized: "Shortcuts"))
        row(nil, button(String(localized: "Keyboard Shortcuts…"), #selector(showKeys(_:))))
        note(String(localized: "Any cm_ command can get its own keys; shortcuts from Total Commander's wincmd.ini can be imported. Keys work on any keyboard layout."))

        section(String(localized: "Function keys"))
        note(String(localized: "On a Mac F1–F12 control brightness and sound by default. Hold fn, or turn on \u{201C}Use F1, F2, etc. keys as standard function keys\u{201D}."))
        row(nil, button(String(localized: "Open Keyboard Settings"), #selector(openKeyboardSettings(_:))))
    }

    @objc private func quickSearchChanged(_ sender: NSPopUpButton) {
        Settings.quickSearchMode = sender.indexOfSelectedItem == 0 ? .optionLetters : .letters
    }

    @objc private func showKeys(_ sender: Any?) {
        KeyBindingsWindowController.shared.showWindow(sender)
    }

    @objc private func openKeyboardSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Preview

/// A small panel drawn with the current font and colors.
private final class PanelPreview: NSView {
    private struct Row {
        let name: String
        let ext: String
        let size: String
        var isFolder = false
        var isMarked = false
        var isCursor = false
    }

    private let rows = [
        Row(name: "..", ext: "", size: "<DIR>", isFolder: true),
        Row(name: "Documents", ext: "", size: "<DIR>", isFolder: true),
        Row(name: "notes", ext: "md", size: "12 345", isMarked: true),
        Row(name: "readme", ext: "txt", size: "4 096", isCursor: true),
        Row(name: "photo", ext: "jpg", size: "2 048 000"),
        Row(name: "archive", ext: "zip", size: "88 000", isMarked: true),
        Row(name: "script", ext: "sh", size: "1 024"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 460).isActive = true
        heightConstraint = heightAnchor.constraint(equalToConstant: height)
        heightConstraint?.isActive = true
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.heightConstraint?.constant = self.height
                self.needsDisplay = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var heightConstraint: NSLayoutConstraint?
    private var headerHeight: CGFloat { 20 }
    private var height: CGFloat { headerHeight + CGFloat(rows.count) * Theme.rowHeight + 2 }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        Theme.panelBackground.setFill()
        bounds.fill()

        // Column headers.
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        Theme.chromeBackground.setFill()
        header.fill()
        let nameWidth = bounds.width - 190
        let columns: [(String, CGFloat, NSTextAlignment)] = [
            (String(localized: "Name"), 6, .left), (String(localized: "Ext"), nameWidth, .left),
            (String(localized: "Size"), nameWidth + 50, .right),
        ]
        for (title, x, alignment) in columns {
            draw(title, in: NSRect(x: x, y: 3, width: alignment == .right ? 130 : 120, height: 16),
                 font: Theme.chromeFont, color: Theme.chromeText, alignment: alignment)
        }
        Theme.separator.setFill()
        NSRect(x: 0, y: headerHeight - 1, width: bounds.width, height: 1).fill()

        let font = Theme.panelFont
        let rowHeight = Theme.rowHeight
        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: 0, y: headerHeight + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            if row.isCursor {
                Theme.cursorBackground.setFill()
                rect.fill()
            } else if ColorSettings.alternatingRows && index % 2 == 1 {
                Theme.alternateRowBackground.setFill()
                rect.fill()
            }
            let fileName = row.ext.isEmpty ? row.name : row.name + "." + row.ext
            var color = ColorSettings.color(forName: fileName) ?? Theme.panelText
            if row.isMarked { color = Theme.markedText }
            if row.isCursor { color = row.isMarked ? Theme.markedCursorText : Theme.cursorText }
            let textY = rect.minY + (rowHeight - (font.ascender - font.descender)) / 2 - 1
            draw(row.isFolder ? "[\(row.name)]" : row.name, in: NSRect(x: 6, y: textY, width: nameWidth - 10, height: rowHeight),
                 font: font, color: color, alignment: .left)
            draw(row.ext, in: NSRect(x: nameWidth, y: textY, width: 48, height: rowHeight), font: font, color: color,
                 alignment: .left)
            draw(row.size, in: NSRect(x: nameWidth + 50, y: textY, width: 130, height: rowHeight),
                 font: Theme.panelNumberFont, color: color, alignment: .right)
        }
        Theme.separator.setStroke()
        NSBezierPath(rect: frame).stroke()
    }

    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}

// MARK: - Restart

/// Quits and starts OriCmd again (for a new interface language).
enum Relaunch {
    static func now() {
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\""
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
