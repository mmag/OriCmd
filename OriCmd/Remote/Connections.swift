import Foundation
import Security

/// A saved server of the connection manager (Net → Connections).
nonisolated struct SavedConnection: Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var address: String
    var remembersPassword = false
}

/// The saved connections, kept in the settings.
enum Connections {
    private static let key = "Connections"

    static var all: [SavedConnection] {
        get {
            guard let data = AppDefaults.store.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
        }
        set { AppDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

/// Passwords of saved connections in the login Keychain. Test runs keep them
/// in memory instead, so they never touch the user's Keychain.
enum Credentials {
    private static let service = "ru.themmag.OriCmd"
    private static var memory: [String: String] = [:]

    private static var usesMemory: Bool {
        #if DEBUG
        return DebugAutomation.initialDirectory(left: true) != nil
        #else
        return false
        #endif
    }

    static func password(for id: UUID) -> String? {
        if usesMemory { return memory[id.uuidString] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        if usesMemory {
            memory[id.uuidString] = password
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "OriCmd connection"
        SecItemAdd(item as CFDictionary, nil)
    }
}
