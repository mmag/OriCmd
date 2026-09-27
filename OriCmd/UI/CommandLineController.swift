import AppKit
import os

@MainActor
protocol CommandLineControllerDelegate: AnyObject {
    /// The folder commands run in: the active panel's directory.
    var commandLineDirectory: URL { get }
    /// The entry under the cursor of the active panel.
    var commandLineCurrentItem: FileItem? { get }
    func commandLine(_ controller: CommandLineController, changeDirectoryTo url: URL)
    func commandLineDidEndEditing(_ controller: CommandLineController)
}

/// Total Commander style command line: characters typed in a panel are
/// appended here while the panel keeps the cursor; Enter runs the command.
final class CommandLineController: NSObject {
    let view = CommandLineView()
    weak var delegate: CommandLineControllerDelegate?

    private static let historyKey = "CommandLineHistory"
    private static let historyLimit = 30

    private var field: NSComboBox { view.inputField }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init() {
        super.init()
        field.delegate = self
        field.addItems(withObjectValues: AppDefaults.store.stringArray(forKey: Self.historyKey) ?? [])
    }

    // MARK: - Keys typed in a panel

    /// Handles a key pressed in a file list. Returns true if the command line consumed it.
    func handlePanelKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        switch (event.specialKey, modifiers) {
        case (.carriageReturn?, [.control]), (.enter?, [.control]):
            if let item = delegate?.commandLineCurrentItem, !item.isParent {
                append(Self.quoted(item.name) + " ")
            }
            return true
        case (.carriageReturn?, [.control, .shift]), (.enter?, [.control, .shift]):
            if let item = delegate?.commandLineCurrentItem, !item.isParent {
                append(Self.quoted(item.url.path) + " ")
            }
            return true
        case (.carriageReturn?, []), (.enter?, []):
            guard !text.isEmpty else { return false }
            execute(inTerminal: false)
            return true
        case (.carriageReturn?, [.shift]), (.enter?, [.shift]):
            guard !text.isEmpty else { return false }
            execute(inTerminal: true)
            return true
        case (.delete?, []):
            guard !text.isEmpty else { return false }
            text.removeLast()
            return true
        case (nil, []), (nil, [.shift]):
            guard let characters = event.characters, Self.isPrintable(characters) else { break }
            if characters == "\u{1b}" { break }
            // With an empty command line these keys mark files instead.
            if text.isEmpty && ["+", "-", "*", " "].contains(characters) { return false }
            append(characters)
            return true
        default:
            break
        }
        if event.characters == "\u{1b}", !text.isEmpty {
            text = ""
            return true
        }
        return false
    }

    private func append(_ string: String) {
        text += string
    }

    private static func isPrintable(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private static func quoted(_ string: String) -> String {
        string.contains(where: { " '\"$`\\()&;|<>*?[]{}!#~".contains($0) })
            ? "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
            : string
    }

    // MARK: - Execution

    /// Runs the command line: `cd` and folder paths change the panel's directory;
    /// anything else runs in the user's login shell (in Terminal with ⇧Enter).
    func execute(inTerminal: Bool) {
        let command = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !command.isEmpty, let delegate else { return }
        remember(command)
        let directory = delegate.commandLineDirectory

        if let target = Self.changeDirectoryTarget(command, relativeTo: directory) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                delegate.commandLine(self, changeDirectoryTo: target)
            } else {
                NSSound.beep()
            }
            return
        }
        if inTerminal {
            ShellRunner.runInTerminal(command, in: directory)
        } else {
            ShellRunner.run(command, in: directory, window: view.window)
        }
    }

    /// "cd", "cd <path>", or a bare path to an existing folder.
    static func changeDirectoryTarget(_ command: String, relativeTo directory: URL) -> URL? {
        var path: String
        if command == "cd" {
            return FileManager.default.homeDirectoryForCurrentUser
        } else if command.hasPrefix("cd ") {
            path = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if path.count >= 2, let first = path.first, (first == "'" || first == "\""), path.last == first {
                path = String(path.dropFirst().dropLast())
            }
        } else if command.hasPrefix("/") || command.hasPrefix("~") || command == ".." {
            path = command
            var isDirectory: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) || path == "..",
                  isDirectory.boolValue || path == ".." else { return nil }
        } else {
            return nil
        }
        path = (path as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
        return url.standardizedFileURL
    }

    private func remember(_ command: String) {
        var history = AppDefaults.store.stringArray(forKey: Self.historyKey) ?? []
        history.removeAll { $0 == command }
        history.insert(command, at: 0)
        history = Array(history.prefix(Self.historyLimit))
        AppDefaults.store.set(history, forKey: Self.historyKey)
        field.removeAllItems()
        field.addItems(withObjectValues: history)
    }
}

extension CommandLineController: NSComboBoxDelegate {
    /// Editing inside the command line itself: Enter runs, Esc/Tab return to the panel.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let inTerminal = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            execute(inTerminal: inTerminal)
            delegate?.commandLineDidEndEditing(self)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            text = ""
            delegate?.commandLineDidEndEditing(self)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            delegate?.commandLineDidEndEditing(self)
            return true
        default:
            return false
        }
    }
}

/// Runs shell commands the way Total Commander runs programs from its command line.
enum ShellRunner {
    private static var shell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Runs detached in the user's login shell; reports a failure with its stderr.
    static func run(_ command: String, in directory: URL, window: NSWindow?) {
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let errors = Pipe()
        let collected = OSAllocatedUnfairLock(initialState: Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.withLock { $0.append(data) }
        }
        process.standardError = errors
        process.terminationHandler = { process in
            errors.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let message = String(decoding: collected.withLock { $0 }, as: UTF8.self)
            guard status != 0 else { return }
            Task { @MainActor in
                let error = TransferError(message: message.isEmpty ? String(localized: "Exit status \(status)") : message)
                Prompt.error(String(localized: "\u{201C}\(command)\u{201D} failed"), error, in: window)
            }
        }
        do {
            try process.run()
        } catch {
            Prompt.error(String(localized: "Cannot run \u{201C}\(command)\u{201D}"), error, in: window)
        }
    }

    /// Runs in a new Terminal window that stays open afterwards (like `cmd /k`).
    static func runInTerminal(_ command: String, in directory: URL) {
        let script = FileManager.default.temporaryDirectory.appending(path: "oricmd-\(UUID().uuidString).command")
        let escapedDirectory = directory.path.replacingOccurrences(of: "'", with: "'\\''")
        let body = """
            #!\(shell) -l
            rm -f "$0"
            cd '\(escapedDirectory)'
            \(command)
            exec "$SHELL" -l

            """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            NSSound.beep()
            return
        }
        openInTerminal(script)
    }

    /// Opens a Terminal window in `directory`.
    static func openTerminal(in directory: URL) {
        openInTerminal(directory)
    }

    private static func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
