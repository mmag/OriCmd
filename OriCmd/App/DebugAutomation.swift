#if DEBUG
import AppKit
import ApplicationServices
import WebKit

/// Development aids driven by environment variables (Debug builds only):
///
/// - `ORICMD_LEFT`, `ORICMD_RIGHT`: initial panel directories.
/// - `ORICMD_KEYS`: space separated keystrokes played after launch, e.g.
///   `down shift+down f7 text:New enter wait`, or commands like `cmd:cm_SyncDirs`,
///   `menu` (writes the context menu to `<snapshot>-menu.txt`), `drop:/path`, `drive:/path` (a drive
///   button), `drivemenu:/path` / `drivemenu:/path|Item_Title` (a drive button's context menu),
///   `droptab:left:1:right:0` (a tab dropped on a tab bar), `wheel:N` (a mouse wheel over a 3D model), `tabbardoubleclick` (the empty end of the tab bar), `tabmiddleclick:N` (the middle button on the active panel's tab N), `tabmenu:N|Item_Title` (a tab's context menu), `menuitem:Submenu>Item_Title` (a main menu item), `file:/path` (the file the next save or open sheet chooses), `pathclick` (the path bar), `colorpreset:N` (Settings → Colors), `rightmouse:click:N` / `hold:N` / `drag:N-M` / `ctrlclick:N` (the right button on rows), `textmenu` (the frontmost text's context menu), `promise:/path` (the file on the
///   clipboard as a promise, plus a placeholder of zeros), `lazyfile:/path` (as Microsoft Remote Desktop
///   does: a placeholder written only when read through file coordination), `click:Button_Title` (also a tab of a tab view),
///   `set:identifier=value` (a control by its identifier: text, a pop-up item's title, `on`/`off`/`mixed`, a
///   date as `2026-01-31`, a table's row by its text; `_` stands for a space),
///   `dropapp:/path/App.app` (onto the toolbar), `clickapp:App_Name`, `rightclickapp:App_Name|Menu_Item`.
///   Only played when both panel directories are given, so a test run never touches real files.
/// - `ORICMD_SNAPSHOT`: PNG path; the window (and an open sheet, as
///   `<name>-sheet.png`, other windows as `<name>-win1.png`…, each with the texts it
///   shows in a `.txt` beside it) is rendered there after the keys are played; a server
///   terminal of the active panel as `<name>-terminal.png` and `.txt`.
/// - `ORICMD_QUIT`: exit when done (even with a sheet open).
enum DebugAutomation {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Keys to play or a snapshot to take: a test run, which stays in the background.
    static var isTestRun: Bool {
        environment["ORICMD_KEYS"] != nil || environment["ORICMD_SNAPSHOT"] != nil
    }

    static func initialDirectory(left: Bool) -> URL? {
        environment[left ? "ORICMD_LEFT" : "ORICMD_RIGHT"].map { URL(filePath: $0) }
    }

    static func run(in window: NSWindow) {
        var keys = environment["ORICMD_KEYS"]?.split(separator: " ").map(String.init) ?? []
        if !keys.isEmpty && (initialDirectory(left: true) == nil || initialDirectory(left: false) == nil) {
            NSLog("ORICMD_KEYS ignored: set ORICMD_LEFT and ORICMD_RIGHT to test directories")
            keys = []
        }
        let snapshot = environment["ORICMD_SNAPSHOT"]
        guard !keys.isEmpty || snapshot != nil else { return }
        ignoreRealInput()

        Task {
            try? await Task.sleep(for: .milliseconds(800))
            for token in keys {
                if token == "wait" {
                    try? await Task.sleep(for: .milliseconds(700))
                } else if token == "menu", let list = window.firstResponder as? FileListView,
                          let menu = list.delegate?.fileList(list, contextMenuFor: list.selectedEntries),
                          let snapshot = environment["ORICMD_SNAPSHOT"] {
                    // Writes the context menu's titles next to the snapshot.
                    let titles = menu.items.map { item in
                        item.isSeparatorItem ? "---" : item.title
                            + (item.submenu.map { " ▸ " + $0.items.map(\.title).joined(separator: " | ") } ?? "")
                    }
                    try? titles.joined(separator: "\n").write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                                                atomically: true, encoding: .utf8)
                } else if token == "textmenu", let snapshot, let text = textView(in: topmost(window).contentView),
                          let event = NSEvent.mouseEvent(
                            with: .rightMouseDown, location: text.convert(NSPoint(x: 20, y: 10), to: nil), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: text.window?.windowNumber ?? 0,
                            context: nil, eventNumber: harnessEventNumber, clickCount: 1, pressure: 1),
                          let menu = text.menu(for: event) {
                    // Writes the context menu of the frontmost window's text (e.g. the Lister's).
                    let titles = menu.items.map { item in
                        item.isSeparatorItem ? "---" : item.title
                            + (item.submenu.map { " ▸ " + $0.items.map { ($0.state == .on ? "✓" : "") + $0.title }
                                .joined(separator: " | ") } ?? "")
                    }
                    try? titles.joined(separator: "\n").write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                                                atomically: true, encoding: .utf8)
                } else if token.hasPrefix("rightmouse:"), let list = window.firstResponder as? FileListView {
                    // The right button on rows of the focused panel: `click:N`, `hold:N` (not
                    // let go), `drag:N-M`, or `ctrlclick:N` (Control and the left button). A
                    // context menu shown is written to <snapshot>-menu.txt (empty when none)
                    // and closed.
                    let parts = token.split(separator: ":").map(String.init)
                    let rows = parts.count == 3 ? parts[2].split(separator: "-").compactMap { Int($0) } : []
                    guard let first = rows.first, let last = rows.last else { continue }
                    let control = parts[1] == "ctrlclick"
                    @MainActor func event(_ type: NSEvent.EventType, at row: Int) -> NSEvent? {
                        let rect = list.rowRect(row)
                        let type: NSEvent.EventType = !control ? type : type == .rightMouseDown ? .leftMouseDown : .leftMouseUp
                        return NSEvent.mouseEvent(
                            with: type, location: list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                            modifierFlags: control ? [.control] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: harnessEventNumber, clickCount: 1,
                            pressure: type == .rightMouseUp || type == .leftMouseUp ? 0 : 1)
                    }
                    let menuFile = snapshot?.replacingOccurrences(of: ".png", with: "-menu.txt")
                    if let menuFile {
                        try? "".write(toFile: menuFile, atomically: true, encoding: .utf8)
                    }
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                          object: nil, queue: nil) { note in
                        nonisolated(unsafe) let tracked = note.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            if let menuFile {
                                try? menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
                                    .write(toFile: menuFile, atomically: true, encoding: .utf8)
                            }
                            nonisolated(unsafe) let shown = menu
                            RunLoop.main.perform(inModes: [.eventTracking, .default]) { shown.cancelTracking() }
                        }
                    }
                    if parts[1] == "drag" {
                        for row in stride(from: first, through: last, by: first <= last ? 1 : -1) {
                            event(.rightMouseDragged, at: row).map { NSApp.postEvent($0, atStart: false) }
                        }
                    }
                    if parts[1] != "hold" {
                        event(.rightMouseUp, at: last).map { NSApp.postEvent($0, atStart: false) }
                    }
                    if control, !NSApp.isActive, let down = event(.rightMouseDown, at: first) {
                        // A test run stays in the background, and a left click on an
                        // inactive window only activates it: the menu is asked for as
                        // AppKit does for a Control-click.
                        list.menu(for: down).map { NSMenu.popUpContextMenu($0, with: down, for: list) }
                    } else {
                        event(.rightMouseDown, at: first).map(window.sendEvent)
                    }
                    NotificationCenter.default.removeObserver(observer)
                } else if token.hasPrefix("drop:"), let list = window.firstResponder as? FileListView {
                    // Simulates dropping a file onto the focused panel.
                    _ = list.delegate?.fileList(list, drop: [URL(filePath: String(token.dropFirst(5)))], into: nil, moving: false)
                } else if token.hasPrefix("drive:"), let main = window.contentViewController as? MainViewController {
                    // Simulates a click on a drive button of the active panel.
                    main.activePanel.panelView.driveBar.onSelect?(URL(filePath: String(token.dropFirst(6))))
                } else if token.hasPrefix("drivemenu:"), let main = window.contentViewController as? MainViewController {
                    // A drive button's context menu (active panel): written to <snapshot>-menu.txt,
                    // or with `|Item_Title` (the start of its title) that item chosen.
                    let parts = token.dropFirst(10).split(separator: "|", maxSplits: 1).map(String.init)
                    let bar = main.activePanel.panelView.driveBar
                    guard let rect = bar.buttonRect(for: URL(filePath: parts[0])),
                          let event = NSEvent.mouseEvent(
                            with: .rightMouseDown, location: bar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: harnessEventNumber,
                            clickCount: 1, pressure: 1),
                          let menu = bar.menu(for: event) else { continue }
                    if parts.count == 2 {
                        let title = parts[1].replacingOccurrences(of: "_", with: " ")
                        if let index = menu.items.firstIndex(where: { $0.title.hasPrefix(title) }) {
                            menu.performActionForItem(at: index)
                        }
                    } else if let snapshot {
                        try? menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
                            .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                   atomically: true, encoding: .utf8)
                    }
                } else if token.hasPrefix("tabmenu:"), let main = window.contentViewController as? MainViewController {
                    // `tabmenu:N` / `tabmenu:N|Item_Title`: the context menu of the active panel's
                    // tab N, written to <snapshot>-menu.txt (✓ before items turned on), or that item chosen.
                    let parts = token.dropFirst(8).split(separator: "|", maxSplits: 1).map(String.init)
                    let bar = main.activePanel.panelView.tabBar
                    guard let tab = Int(parts[0]), let center = bar.center(ofTab: tab),
                          let event = NSEvent.mouseEvent(
                            with: .rightMouseDown, location: bar.convert(center, to: nil), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: harnessEventNumber, clickCount: 1, pressure: 1),
                          let menu = bar.menu(for: event) else { continue }
                    if parts.count == 2 {
                        let title = parts[1].replacingOccurrences(of: "_", with: " ")
                        if let index = menu.items.firstIndex(where: { $0.title.hasPrefix(title) && $0.isEnabled }) {
                            menu.performActionForItem(at: index)
                        }
                    } else if let snapshot {
                        try? menu.items.map { $0.isSeparatorItem ? "---" : ($0.state == .on ? "✓" : "") + $0.title }
                            .joined(separator: "\n")
                            .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                   atomically: true, encoding: .utf8)
                    }
                } else if token.hasPrefix("file:") {
                    // The file the next save or open sheet would have chosen.
                    chosenFile = String(token.dropFirst(5))
                } else if token.hasPrefix("menuitem:") {
                    // `menuitem:Title` or `menuitem:Submenu>Title`: the first enabled item of the main
                    // menu so titled (menus made when opened are made first) is chosen.
                    let path = token.dropFirst(9).replacingOccurrences(of: "_", with: " ").split(separator: ">").map(String.init)
                    @MainActor func choose(_ path: [String], in menu: NSMenu) -> Bool {
                        menu.delegate?.menuNeedsUpdate?(menu)
                        for (index, item) in menu.items.enumerated() {
                            if path.count == 1, item.title == path[0], item.submenu == nil {
                                // A test run is in the background, with no key window for
                                // the responder chain: an item without a target is sent the
                                // way `cmd:` sends commands.
                                if item.target == nil, let action = item.action {
                                    _ = perform(action, in: window, from: item)
                                } else {
                                    menu.performActionForItem(at: index)
                                }
                                return true
                            }
                            if let submenu = item.submenu,
                               choose(item.title == path[0] && path.count > 1 ? Array(path.dropFirst()) : path, in: submenu) {
                                return true
                            }
                        }
                        return false
                    }
                    if let menu = NSApp.mainMenu { _ = choose(path, in: menu) }
                } else if token.hasPrefix("droptab:"), let main = window.contentViewController as? MainViewController {
                    // `droptab:left:1:right:0`: the left panel's second tab dropped before the
                    // right panel's first (as a finished drag).
                    let parts = token.split(separator: ":").map(String.init)
                    let panels = ["left": main.panels[0], "right": main.panels[1]]
                    guard parts.count == 5, let source = panels[parts[1]], let tab = Int(parts[2]),
                          let target = panels[parts[3]], let position = Int(parts[4]),
                          source.tabs.indices.contains(tab) else { continue }
                    _ = target.panelView.tabBar.drop(source.tabs[tab].id, at: position)
                } else if token.hasPrefix("wheel:"), let lines = Double(token.dropFirst(6)),
                          let model = topmost(window).contentView as? ModelView {
                    // A mouse wheel turned over the Lister's 3D model (lines > 0: up).
                    model.zoom(lines: lines)
                } else if token.hasPrefix("colorpreset:"), let index = Int(token.dropFirst(12)),
                          ColorSettings.Preset.allCases.indices.contains(index) {
                    ColorSettings.Preset.allCases[index].apply()
                } else if token == "pathclick", let main = window.contentViewController as? MainViewController {
                    // A click on the active panel's path bar (it becomes editable).
                    main.activePanel.panelView.pathBar.onClick?()
                    main.activePanel.panelView.pathBar.beginEditing()
                } else if token == "tabbardoubleclick", let main = window.contentViewController as? MainViewController {
                    // A double click on the empty end of the active panel's tab bar.
                    let bar = main.activePanel.panelView.tabBar
                    let point = bar.convert(NSPoint(x: bar.bounds.maxX - 4, y: bar.bounds.midY), to: nil)
                    if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: harnessEventNumber,
                                                      clickCount: 2, pressure: 1) {
                        bar.mouseDown(with: event)
                    }
                } else if token.hasPrefix("tabmiddleclick:"), let tab = Int(token.dropFirst(15)),
                          let main = window.contentViewController as? MainViewController,
                          let center = main.activePanel.panelView.tabBar.center(ofTab: tab) {
                    // The middle button (the mouse wheel) pressed and let go on a tab of the
                    // active panel's tab bar.
                    let bar = main.activePanel.panelView.tabBar
                    let point = bar.convert(center, to: nil)
                    for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                        // AppKit makes no other-button events of its own: the button number
                        // is set through Quartz.
                        guard let cgEvent = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: harnessEventNumber, clickCount: 1,
                            pressure: type == .otherMouseDown ? 1 : 0)?.cgEvent else { continue }
                        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                        guard let event = NSEvent(cgEvent: cgEvent) else { continue }
                        type == .otherMouseDown ? bar.otherMouseDown(with: event) : bar.otherMouseUp(with: event)
                    }
                } else if token.hasPrefix("lazyfile:") {
                    offerLazyFile(URL(filePath: String(token.dropFirst(9))))
                } else if token.hasPrefix("promise:") {
                    offerPromise(of: URL(filePath: String(token.dropFirst(8))))
                } else if token.hasPrefix("dropapp:") {
                    // Simulates dropping an application onto the toolbar.
                    (window.windowController as? MainWindowController)?
                        .addApplications([URL(filePath: String(token.dropFirst(8)))])
                } else if token.hasPrefix("clickapp:") {
                    // Clicks the toolbar button of that application.
                    let name = String(token.dropFirst(9)).replacingOccurrences(of: "_", with: " ")
                    (window.toolbar?.items.compactMap { $0.view as? AppButton }
                        .first { ToolbarApps.name(of: $0.path) == name })?.performClick(nil)
                } else if token.hasPrefix("rightclickapp:") {
                    // Right-clicks the toolbar button of an application; the menu shown is
                    // written to <snapshot>-menu.txt and its item named after "|" is chosen.
                    // No menu shown (no such button, or a sheet is open) leaves the file empty.
                    let parts = String(token.dropFirst(14)).replacingOccurrences(of: "_", with: " ")
                        .split(separator: "|", maxSplits: 1).map(String.init)
                    if let snapshot {
                        try? "".write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                      atomically: true, encoding: .utf8)
                    }
                    guard let mainWindow = window as? MainWindow,
                          let button = window.toolbar?.items.compactMap({ $0.view as? AppButton })
                            .first(where: { ToolbarApps.name(of: $0.path) == parts[0] }),
                          let event = NSEvent.mouseEvent(
                            with: .rightMouseDown, location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: harnessEventNumber, clickCount: 1, pressure: 1)
                    else { continue }
                    let choice = parts.count > 1 ? parts[1] : nil
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                          object: nil, queue: nil) { note in
                        nonisolated(unsafe) let tracked = note.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            if let snapshot {
                                try? menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
                                    .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-menu.txt"),
                                           atomically: true, encoding: .utf8)
                            }
                            nonisolated(unsafe) let shown = menu
                            let index = menu.items.firstIndex { $0.title == choice }
                            RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                                shown.cancelTracking()
                                if let index {
                                    shown.performActionForItem(at: index)
                                }
                            }
                        }
                    }
                    _ = mainWindow.showAppButtonMenu(for: event)
                    NotificationCenter.default.removeObserver(observer)
                } else if token.hasPrefix("importini:") {
                    _ = try? KeyBindings.importTotalCommanderShortcuts(from: URL(filePath: String(token.dropFirst(10))))
                } else if token.hasPrefix("click:") {
                    // Presses the button with that title in the topmost window.
                    let title = String(token.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
                    @MainActor func find(_ view: NSView?) -> NSButton? {
                        guard let view else { return nil }
                        if let button = view as? NSButton, button.title == title { return button }
                        return view.subviews.lazy.compactMap(find).first
                    }
                    if let button = find(topmost(window).contentView) {
                        button.performClick(nil)
                    } else if let tabs = views(in: topmost(window).contentView).compactMap({ $0 as? NSTabView }).first(where: {
                        $0.tabViewItems.contains { $0.label == title }
                    }) {
                        tabs.selectTabViewItem(tabs.tabViewItems.first { $0.label == title })
                    }
                } else if token.hasPrefix("set:"), let equals = token.firstIndex(of: "=") {
                    // `set:identifier=value`: a control of the topmost window set as by the
                    // user, its action sent.
                    let name = String(token[token.index(token.startIndex, offsetBy: 4)..<equals])
                    let value = String(token[token.index(after: equals)...]).replacingOccurrences(of: "_", with: " ")
                    guard let control = views(in: topmost(window).contentView)
                        .first(where: { $0.identifier?.rawValue == name }) as? NSControl else { continue }
                    switch control {
                    case let table as NSTableView:
                        // The row showing that text in its first column.
                        let row = (0..<table.numberOfRows).first { row in
                            table.tableColumns.first.flatMap { table.dataSource?.tableView?(table, objectValueFor: $0, row: row) }
                                .map { "\($0)" } == value
                        }
                        table.selectRowIndexes(row.map { [$0] } ?? [], byExtendingSelection: false)
                    case let popup as NSPopUpButton: popup.selectItem(withTitle: value)
                    case let box as NSButton: box.state = value == "on" ? .on : value == "mixed" ? .mixed : .off
                    case let picker as NSDatePicker:
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        if let date = formatter.date(from: value) { picker.dateValue = date }
                    default: control.stringValue = value
                    }
                    if let action = control.action {
                        NSApp.sendAction(action, to: control.target, from: control)
                    }
                } else if token.hasPrefix("cmd:") {
                    perform(Selector(String(token.dropFirst(4)) + ":"), in: window)
                } else if token.hasPrefix("text:") {
                    type(String(token.dropFirst(5)), in: window)
                } else if let stroke = KeyStroke(token) {
                    play(stroke, in: window)
                } else {
                    NSLog("Unknown key token: \(token)")
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            try? await Task.sleep(for: .milliseconds(400))
            if let snapshot {
                save(window, to: snapshot)
                // Where the panels are: the path shown, the cursor's name, the tabs.
                if let main = window.contentViewController as? MainViewController {
                    let lines = zip(["left", "right"], main.panels).map { side, panel in
                        "\(side)\(panel === main.activePanel ? "*" : ""): \(panel.panelView.pathBar.path)"
                            + " | cursor: \(panel.listView.currentItem?.name ?? "")"
                            + " | tabs: \(panel.panelView.tabBar.titles.joined(separator: ", "))"
                    } + zip(["left", "right"], main.panels).map { side, panel in
                        // The entries listed (the first 30), the marked ones with *.
                        "\(side) items: " + panel.listView.items.filter { !$0.isParent }.prefix(30).map { item in
                            (panel.listView.marked.contains(item.name) ? "*" : "") + item.name
                        }.joined(separator: ", ")
                    }
                    try? lines.joined(separator: "\n").write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-panels.txt"),
                                                            atomically: true, encoding: .utf8)
                }
                // The active panel's terminal, as text and as a picture of its own
                // (its layer's drawing does not show in the window's picture).
                if let main = window.contentViewController as? MainViewController,
                   let terminal = main.activePanel.panelView.terminalPane.terminal {
                    try? main.activePanel.panelView.terminalPane.screenText?
                        .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-terminal.txt"),
                               atomically: true, encoding: .utf8)
                    save(terminal, to: snapshot.replacingOccurrences(of: ".png", with: "-terminal.png"))
                }
                var sheet = window.attachedSheet
                var suffix = "-sheet"
                while let current = sheet {
                    save(current, to: snapshot.replacingOccurrences(of: ".png", with: "\(suffix).png"))
                    saveTexts(of: current, to: snapshot.replacingOccurrences(of: ".png", with: "\(suffix).txt"))
                    sheet = current.attachedSheet
                    suffix += "2"
                }
                try? "kills: \(SyntaxHighlighter.kills)\ntexts: \(SyntaxHighlighter.textsSent)\n"
                    .write(toFile: snapshot.replacingOccurrences(of: ".png", with: "-highlighter.txt"),
                           atomically: true, encoding: .utf8)
                let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.sheetParent == nil }
                for (index, other) in others.enumerated() {
                    save(other, to: snapshot.replacingOccurrences(of: ".png", with: "-win\(index + 1).png"))
                    saveTexts(of: other, to: snapshot.replacingOccurrences(of: ".png", with: "-win\(index + 1).txt"))
                    if let model = other.contentView as? ModelView,
                       let tiff = model.snapshot().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(filePath: snapshot.replacingOccurrences(of: ".png", with: "-win\(index + 1)-model.png")))
                    }
                    if let web = webView(in: other.contentView) {
                        await savePage(web, to: snapshot.replacingOccurrences(of: ".png", with: "-win\(index + 1)-page"))
                    }
                }
            }
            if environment["ORICMD_QUIT"] != nil {
                exit(0)
            }
        }
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap(textView(in:)).first
    }

    /// Set in a test run: other event monitors (Esc) leave real input alone too; the
    /// harness hands them its own keys itself.
    private(set) static var ignoresRealInput = false

    /// The file given with `file:/path` for the next save or open sheet.
    private static var chosenFile: String?

    /// Takes the file given with `file:` (once), instead of asking in a sheet.
    static func takeChosenFile() -> String? {
        defer { chosenFile = nil }
        return chosenFile
    }

    /// Mouse events the harness makes carry this number (real ones count from 0).
    private static let harnessEventNumber = 0x0C1D_0000

    /// A test run ignores the real keyboard and mouse: what the user types or clicks
    /// while its window is in front would otherwise play in the test, and could take
    /// it out of the test folders. The harness's keys go to the windows directly, its
    /// mouse events carry `harnessEventNumber`.
    private static func ignoreRealInput() {
        ignoresRealInput = true
        let input: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
            .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
            .magnify, .swipe, .rotate, .smartMagnify, .beginGesture, .endGesture, .pressure,
        ]
        _ = NSEvent.addLocalMonitorForEvents(matching: input) { event in
            let isMouse = event.type != .keyDown && event.type != .keyUp && event.type != .flagsChanged
            return isMouse && event.eventNumber == harnessEventNumber ? event : nil
        }
    }

    /// `view` and everything inside it, the views of a tab view's hidden tabs too.
    private static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        let hidden = (view as? NSTabView)?.tabViewItems.filter { $0 !== ($0.tabView?.selectedTabViewItem) }
            .compactMap(\.view) ?? []
        return [view] + (view.subviews + hidden).flatMap(views(in:))
    }

    /// Writes the texts `window` shows (its title, labels, fields, text views, the
    /// rows of a table drawn by cells), one per line.
    private static func saveTexts(of window: NSWindow, to path: String) {
        func texts(in view: NSView) -> [String] {
            var result: [String] = []
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                result.append(field is NSSecureTextField ? "[secure]" : field.stringValue)
            }
            if let table = view as? NSTableView, let source = table.dataSource,
               !(table.delegate?.responds(to: #selector(NSTableViewDelegate.tableView(_:viewFor:row:))) ?? false) {
                result += (0..<(source.numberOfRows?(in: table) ?? 0)).map { row in
                    "[row] " + table.tableColumns.map { column in
                        source.tableView?(table, objectValueFor: column, row: row).map { "\($0)" } ?? ""
                    }.joined(separator: " | ")
                }
            }
            if let pages = view as? DjVuPagesView { result.append("[pages drawn: \(pages.drawnCount)]") }
            if let model = view as? ModelView { result.append("[model: \(model.triangleCount) triangles]") }
            if let text = view as? NSTextView, !text.string.isEmpty {
                result.append(text.string)
                // How many text colors it shows (syntax highlighting).
                var colors = Set<NSColor>()
                text.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) {
                    value, _, _ in if let color = value as? NSColor { colors.insert(color) }
                }
                result.append("[text colors: \(colors.count)]")
            }
            return result + view.subviews.flatMap(texts(in:))
        }
        let lines = (window.title.isEmpty ? [] : [window.title]) + (window.contentView.map(texts(in:)) ?? [])
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Inserts text into the focused text field, or types it into the focused view.
    /// The window that receives keys: the frontmost window (e.g. a Lister)
    /// or its topmost sheet.
    private static func topmost(_ window: NSWindow) -> NSWindow {
        // An app in the background (the user works in another one) keeps its main
        // window first in the order: then the newest window (the highest number) is
        // the one just opened.
        let candidates = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil && $0.canBecomeKey }
        var target = (NSApp.isActive ? NSApp.orderedWindows.first { candidates.contains($0) }
            : candidates.max { $0.windowNumber < $1.windowNumber }) ?? window
        while let sheet = target.attachedSheet {
            target = sheet
        }
        return target
    }

    private static func type(_ text: String, in window: NSWindow) {
        let target = topmost(window)
        if let editor = target.firstResponder as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            for character in text {
                play(KeyStroke(characters: String(character), keyCode: 0), in: window)
            }
        }
    }

    /// Delivers a keystroke the way AppKit does: window key equivalents
    /// (default buttons), then menu key equivalents, then `keyDown`.
    private static func play(_ stroke: KeyStroke, in window: NSWindow) {
        KeyboardLayout.simulatesNonLatinLayout = stroke.isRussian
        defer { KeyboardLayout.simulatesNonLatinLayout = false }
        let target = topmost(window)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: stroke.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, characters: stroke.characters,
                charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
                isARepeat: false, keyCode: stroke.keyCode
            ) else { continue }
            if type == .keyDown {
                // Esc as the app-wide monitor sees it before anything else.
                if EscapeKey.handle(event, in: target) { break }
                if target.sheetParent != nil, stroke.characters == "\r", let cell = target.defaultButtonCell {
                    cell.performClick(nil)
                    break
                }
                if target.sheetParent != nil, let button = button(for: stroke, in: target.contentView) {
                    button.performClick(nil)
                    break
                }
                // Return reaches the focused view first unless a text field is being
                // edited, in which case the default button takes it (as in AppKit).
                // A web view takes every key as an equivalent; AppKit asks it only
                // for Command and Control ones.
                let isReturn = stroke.characters == "\r"
                let toWebView = target.firstResponder is WKWebView && stroke.modifiers.isDisjoint(with: [.command, .control])
                if !isReturn || target.firstResponder is NSTextView, !toWebView,
                   target.performKeyEquivalent(with: event) { break }
                if target.attachedSheet == nil, target.sheetParent == nil,
                   performMenuShortcut(event, in: target) || event.latinized.map({ performMenuShortcut($0, in: target) }) == true {
                    break
                }
            }
            target.sendEvent(event)
        }
    }

    /// The sheet button whose key equivalent matches `stroke` (Return, Escape…).
    private static func button(for stroke: KeyStroke, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.isEnabled,
           button.keyEquivalent == stroke.characters,
           button.keyEquivalentModifierMask == stroke.modifiers.subtracting(.function) {
            return button
        }
        for subview in view.subviews {
            if let found = button(for: stroke, in: subview) { return found }
        }
        return nil
    }

    /// Sends a command (e.g. `cm_SyncDirs:`) along the window's responder chain.
    @discardableResult
    private static func perform(_ action: Selector, in window: NSWindow, from sender: Any? = nil) -> Bool {
        var responder = topmost(window).firstResponder
        while let current = responder {
            if current.responds(to: action) {
                return NSApp.sendAction(action, to: current, from: sender)
            }
            if let supplemental = current.supplementalTarget(forAction: action, sender: sender) {
                return NSApp.sendAction(action, to: supplemental, from: sender)
            }
            responder = current.nextResponder
        }
        if let delegate = NSApp.delegate, delegate.responds(to: action) {
            return NSApp.sendAction(action, to: delegate, from: sender)
        }
        NSLog("No target for \(action)")
        return false
    }

    /// Finds the menu item for `stroke` and sends its action along the window's
    /// responder chain. Unlike `NSMenu.performKeyEquivalent`, this also works
    /// while the app is inactive (e.g. the screen is locked during a test run).
    private static func performMenuShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.subtracting(.function)
        func find(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
                if item.keyEquivalent == event.charactersIgnoringModifiers,
                   item.keyEquivalentModifierMask == modifiers,
                   !item.isHidden || item.allowsKeyEquivalentWhenHidden {
                    return item
                }
            }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap(find(in:)), let action = item.action else { return false }

        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) {
                return NSApp.sendAction(action, to: current, from: item)
            }
            if let supplemental = current.supplementalTarget(forAction: action, sender: item) {
                return NSApp.sendAction(action, to: supplemental, from: item)
            }
            responder = current.nextResponder
        }
        if let delegate = NSApp.delegate, delegate.responds(to: action) {
            return NSApp.sendAction(action, to: delegate, from: item)
        }
        return false
    }

    private static var lazyFilePresenter: LazyFilePresenter?

    /// Puts on the (test) clipboard a placeholder of `file`, zero-filled and sparse, that
    /// is written only when someone reads it through file coordination.
    private static func offerLazyFile(_ file: URL) {
        let placeholders = file.deletingLastPathComponent().deletingLastPathComponent().appending(path: "placeholder")
        try? FileManager.default.createDirectory(at: placeholders, withIntermediateDirectories: true)
        let placeholder = placeholders.appending(path: file.lastPathComponent)
        FileManager.default.createFile(atPath: placeholder.path, contents: nil)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let handle = try? FileHandle(forWritingTo: placeholder) {
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        let presenter = LazyFilePresenter(placeholder: placeholder, source: file)
        NSFileCoordinator.addFilePresenter(presenter)
        lazyFilePresenter = presenter
        AppDefaults.pasteboard.clearContents()
        AppDefaults.pasteboard.writeObjects([placeholder as NSURL])
    }

    /// The file promised by `offerPromise` (the promise keeper is a C function), and the
    /// pasteboard reference that keeps the promise (released, it could not be kept).
    nonisolated(unsafe) private static var promisedFile: URL?
    private static var promiseBoard: Pasteboard?

    /// Writes the promised file into the receiver's paste location. Called on the
    /// receiver's thread (a local promise), so not isolated to the main actor.
    nonisolated private static let promiseKeeper: PasteboardPromiseKeeperProcPtr = { board, item, flavor, _ in
        var location: CFURL?
        guard PasteboardCopyPasteLocation(board, &location) == noErr,
              let folder = location as URL?, let source = DebugAutomation.promisedFile else {
            return OSStatus(badPasteboardFlavorErr)
        }
        let target = folder.appending(path: source.lastPathComponent)
        try? FileManager.default.copyItem(at: source, to: target)
        return PasteboardPutItemFlavor(board, item, flavor, Data(target.absoluteString.utf8) as CFData, [])
    }

    /// Puts `file` on the (test) clipboard as Microsoft Remote Desktop does: a promise
    /// of the file, and the URL of a placeholder of the same size full of zeros, in a
    /// "placeholder" folder next to the file's folder.
    private static func offerPromise(of file: URL) {
        var created: Pasteboard?
        guard PasteboardCreate(AppDefaults.pasteboard.name.rawValue as CFString, &created) == noErr,
              let board = created else { return }
        PasteboardClear(board)
        PasteboardSynchronize(board)
        promisedFile = file
        promiseBoard = board
        PasteboardSetPromiseKeeper(board, promiseKeeper, nil)
        guard let item = PasteboardItemID(bitPattern: 1) else { return }
        PasteboardPutItemFlavor(board, item, kPasteboardTypeFileURLPromise as CFString, nil, [])
        PasteboardPutItemFlavor(board, item, kPasteboardTypeFilePromiseContent as CFString,
                                Data("public.data".utf8) as CFData, [])
        let placeholders = file.deletingLastPathComponent().deletingLastPathComponent().appending(path: "placeholder")
        try? FileManager.default.createDirectory(at: placeholders, withIntermediateDirectories: true)
        let placeholder = placeholders.appending(path: file.lastPathComponent)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        FileManager.default.createFile(atPath: placeholder.path, contents: Data(count: size))
        PasteboardPutItemFlavor(board, item, "public.file-url" as CFString,
                                Data(placeholder.absoluteString.utf8) as CFData, [])
    }

    private static func webView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        return view as? WKWebView ?? view.subviews.lazy.compactMap(webView(in:)).first
    }

    /// A web page's title, text and its frames' texts (`<path>.txt`: read by OriCmd's
    /// own script, which runs while the page's are off) and its picture (`<path>.png`).
    private static func savePage(_ web: WKWebView, to path: String) async {
        let text = try? await web.callAsyncJavaScript(
            "return [document.title, document.body ? document.body.innerText : ''].concat(" +
            "[...document.querySelectorAll('iframe')].map(f => 'iframe: ' + (f.contentDocument && " +
            "f.contentDocument.body ? f.contentDocument.body.innerText : ''))).join('\\n')",
            contentWorld: .defaultClient)
        try? ((text as? String) ?? "").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        if let image = try? await web.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path + ".png"))
        }
    }

    private static func save(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview else { return }
        save(view, to: path)
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }
}

/// A keystroke described as text: "down", "shift+f6", "cmd+a", "x".
private struct KeyStroke {
    var characters: String
    var charactersIgnoringModifiers: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags = []
    /// Typed with the Russian layout active ("ru+").
    var isRussian = false

    init(characters: String, keyCode: UInt16) {
        self.characters = characters
        self.charactersIgnoringModifiers = characters
        self.keyCode = keyCode
    }

    private static let special: [String: (Int, UInt16)] = [
        "up": (NSUpArrowFunctionKey, 126), "down": (NSDownArrowFunctionKey, 125),
        "left": (NSLeftArrowFunctionKey, 123), "right": (NSRightArrowFunctionKey, 124),
        "pageup": (NSPageUpFunctionKey, 116), "pagedown": (NSPageDownFunctionKey, 121),
        "home": (NSHomeFunctionKey, 115), "end": (NSEndFunctionKey, 119),
        "insert": (NSInsertFunctionKey, 114), "forwarddelete": (NSDeleteFunctionKey, 117),
        "enter": (0x0D, 36), "tab": (0x09, 48), "backspace": (0x7F, 51),
        "space": (0x20, 49), "escape": (0x1B, 53),
        "f1": (NSF1FunctionKey, 122), "f2": (NSF2FunctionKey, 120), "f3": (NSF3FunctionKey, 99),
        "f4": (NSF4FunctionKey, 118), "f5": (NSF5FunctionKey, 96), "f6": (NSF6FunctionKey, 97),
        "f7": (NSF7FunctionKey, 98), "f8": (NSF8FunctionKey, 100), "f9": (NSF9FunctionKey, 101),
        "f10": (NSF10FunctionKey, 109), "f11": (NSF11FunctionKey, 103), "f12": (NSF12FunctionKey, 111),
        "plus": (0x2B, 24), "minus": (0x2D, 27), "star": (0x2A, 28),
    ]

    /// ANSI key codes, so menus match synthetic events like real ones.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "§": 10,
    ]

    /// The Russian (PC) layout on the keys of the US one, if the real one is missing.
    private static let russian: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(
        "qwertyuiop[]asdfghjkl;'zxcvbnm,.`", "йцукенгшщзхъфывапролджэячсмитьбюё"
    ))

    init?(_ token: String) {
        var parts = token.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        var russian = false
        for part in parts {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "num": modifiers.insert(.numericPad)
            case "ru": russian = true
            default: return nil
            }
        }
        if let (code, keyCode) = Self.special[key] {
            self.init(characters: String(UnicodeScalar(UInt32(code))!), keyCode: keyCode)
            if code >= 0xF700 {
                modifiers.insert(.function)
            }
        } else if key.count == 1 {
            self.init(characters: key, keyCode: Self.keyCodes[Character(key)] ?? 0)
            // "ru+ctrl+d": the same key typed with the Russian – PC layout active ("в";
            // "`" is "]" there on ISO keyboards, "ё" on ANSI ones).
            if russian, let typed = KeyboardLayout.character(keyCode: keyCode, onLayout: "com.apple.keylayout.RussianWin")
                ?? Self.russian[Character(key)].map(String.init) {
                characters = typed
                charactersIgnoringModifiers = typed
                isRussian = true
            }
        } else {
            return nil
        }
        self.modifiers = modifiers
    }
}
/// Writes the placeholder's contents when a coordinated reader asks (as Microsoft
/// Remote Desktop does with the files it puts on the clipboard).
nonisolated private final class LazyFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let source: URL

    init(placeholder: URL, source: URL) {
        presentedItemURL = placeholder
        self.source = source
    }

    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        guard let placeholder = presentedItemURL else { return completionHandler(nil) }
        completionHandler(Result { try Data(contentsOf: source).write(to: placeholder) }.error)
    }
}

nonisolated private extension Result where Failure == Error {
    var error: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
#endif
