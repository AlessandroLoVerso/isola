import Foundation
import Security

/// The pairing key (20 bytes) in the login Keychain, as a generic password. Never in UserDefaults or logs.
enum Keychain {
    private static let service = "it.isola.ponte"
    private static let account = "chiave-abbinamento"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return data.count == 20 ? data : nil
    }

    @discardableResult
    static func save(_ key: Data) -> Bool {
        let update: [String: Any] = [kSecValueData as String: key]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = key
        add[kSecAttrLabel as String] = "Isola Ponte: chiave di abbinamento"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
