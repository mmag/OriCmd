import Foundation

/// A Find Files search saved under a name: every condition of the dialog but the
/// folder, which comes from the panel. Pop-ups are kept by the index of their item.
struct SearchTemplate: Codable {
    var name: String

    var masks: String
    var nameIsRegex: Bool
    var depth: Int
    var inArchives: Bool
    var usesIndex: Bool
    var text: String
    var caseSensitive: Bool
    var wholeWords: Bool
    var textIsRegex: Bool
    var notContaining: Bool
    var encoding: Int

    var between: Bool
    var from: Date
    var to: Date
    var older: Bool
    var age: String
    var ageUnit: Int
    var size: Bool
    var sizeComparison: Int
    var sizeValue: String
    var sizeUnit: Int
    /// The attribute checkboxes by attribute: 1 has it, 0 does not, -1 any.
    var attributes: [String: Int]
    var duplicates: Bool
    var sameName: Bool
    var sameSize: Bool
    var sameContents: Bool

    private static let key = "FindFilesTemplates"

    /// The saved templates, in the order saved; none if they cannot be read.
    static var saved: [SearchTemplate] {
        get {
            AppDefaults.store.data(forKey: key).flatMap { try? JSONDecoder().decode([SearchTemplate].self, from: $0) } ?? []
        }
        set {
            AppDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}
