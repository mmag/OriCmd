import Foundation

/// Total Commander style file masks: "*.txt;*.md" or "*.txt *.md".
enum FileMask {
    nonisolated static func matches(_ name: String, _ masks: String) -> Bool {
        let patterns = masks.split { $0 == ";" || $0 == " " }.map(String.init)
        return patterns.contains { pattern in
            pattern == "*" || pattern == "*.*" || fnmatch(pattern, name, FNM_CASEFOLD) == 0
        }
    }

    nonisolated static func matchesAny(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern == "*" || pattern == "*.*" || fnmatch(pattern, name, FNM_CASEFOLD) == 0
        }
    }
}
