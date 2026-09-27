import AppKit

/// Total Commander's internal associations: which program opens (Enter),
/// views (F3) and edits (F4) the files matching a mask.
nonisolated struct FileAssociation: Codable, Equatable, Sendable {
    enum Action {
        case open, view, edit
    }

    var id = UUID()
    var mask: String
    var open = ""
    var view = ""
    var edit = ""

    func program(for action: Action) -> String {
        let program = switch action {
        case .open: open
        case .view: view
        case .edit: edit
        }
        return program.trimmingCharacters(in: .whitespaces)
    }
}

/// The associations, stored in the settings; the first matching mask with a
/// program for the action wins.
enum FileAssociations {
    static let didChange = Notification.Name("OriCmdFileAssociationsDidChange")
    private static let key = "FileAssociations"

    static var all: [FileAssociation] {
        get {
            guard let data = AppDefaults.store.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([FileAssociation].self, from: data)) ?? []
        }
        set {
            AppDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The program associated with `action` for a file named `name`, if any.
    static func program(for action: FileAssociation.Action, name: String) -> String? {
        all.lazy
            .filter { !$0.mask.isEmpty && FileMask.matches(name, $0.mask) }
            .map { $0.program(for: action) }
            .first { !$0.isEmpty }
    }

    /// Opens `file` with the program associated with `action`.
    /// Returns false when there is none, so the caller does its default.
    @discardableResult
    static func perform(_ action: FileAssociation.Action, on file: URL, window: NSWindow?) -> Bool {
        guard let program = program(for: action, name: file.lastPathComponent) else { return false }
        launch(program, with: file, window: window)
        return true
    }

    /// An application (a path to an .app) opens the file itself; anything else is a
    /// shell command with %P (the file's folder) and %N (its name), or with the
    /// quoted path added at the end when it has neither.
    static func launch(_ program: String, with file: URL, window: NSWindow?) {
        if let application = application(at: program) {
            NSWorkspace.shared.open([file], withApplicationAt: application,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in
                    Prompt.error(String(localized: "Cannot run \u{201C}\(program)\u{201D}"), error, in: window)
                }
            }
            return
        }
        let folder = file.deletingLastPathComponent()
        ShellRunner.run(commandLine(program, for: file), in: folder, window: window)
    }

    nonisolated static func commandLine(_ program: String, for file: URL) -> String {
        guard program.contains("%") else {
            return program + " " + UserCommand.quoted(file.path)
        }
        let folder = file.deletingLastPathComponent().path
        let context = UserCommand.Context(sourcePath: folder, currentName: file.lastPathComponent,
                                          selectedNames: [file.lastPathComponent], targetPath: folder, targetName: nil)
        return UserCommand(title: "", command: program).expanded(with: context)
    }

    /// The application `program` names: a path to an .app bundle.
    static func application(at program: String) -> URL? {
        let path = (program as NSString).expandingTildeInPath
        guard path.hasSuffix(".app") || path.hasSuffix(".app/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
