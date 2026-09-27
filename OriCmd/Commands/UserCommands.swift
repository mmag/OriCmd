import Foundation

/// An entry of the "Start" menu: a shell command with Total Commander style
/// parameters, optionally with its own key and run in Terminal.
nonisolated struct UserCommand: Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var command: String
    var keys = ""
    var runsInTerminal = false

    /// Values for the parameters, taken from the panels.
    struct Context {
        var sourcePath: String
        var currentName: String?
        var selectedNames: [String]
        var targetPath: String
        var targetName: String?
    }

    /// Replaces %P (source folder), %N (name under the cursor), %S (selected
    /// names), %T (target folder), %M (name under the cursor in the target
    /// panel) and %% with shell-quoted values.
    func expanded(with context: Context) -> String {
        var result = ""
        var iterator = command.makeIterator()
        while let character = iterator.next() {
            guard character == "%", let code = iterator.next() else {
                result.append(character)
                continue
            }
            switch code {
            case "P": result += Self.quoted(Self.withSlash(context.sourcePath))
            case "N": result += context.currentName.map(Self.quoted) ?? ""
            case "S": result += context.selectedNames.map(Self.quoted).joined(separator: " ")
            case "T": result += Self.quoted(Self.withSlash(context.targetPath))
            case "M": result += context.targetName.map(Self.quoted) ?? ""
            case "%": result += "%"
            default: result += "%" + String(code)
            }
        }
        return result
    }

    private static func withSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The user's Start menu, stored in the settings.
enum UserCommands {
    static let didChange = Notification.Name("OriCmdUserCommandsDidChange")
    private static let key = "UserCommands"

    static var all: [UserCommand] {
        get {
            guard let data = AppDefaults.store.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([UserCommand].self, from: data)) ?? []
        }
        set {
            AppDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func command(withID id: String) -> UserCommand? {
        all.first { $0.id.uuidString == id }
    }
}
