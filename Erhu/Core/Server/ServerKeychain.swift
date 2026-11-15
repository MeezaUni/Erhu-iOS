import Foundation
import Security

/// Server passwords in the iOS Keychain, one item per server account. Readable after the first
/// unlock (streaming continues on the Lock Screen) and never synced to other devices.
enum ServerKeychain {
    private static let service = "org.erhu.music-server"

    static func password(for accountId: UUID) -> String? {
        var query = baseQuery(accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ password: String, for accountId: UUID) -> Bool {
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(accountId) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery(accountId)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func removePassword(for accountId: UUID) {
        SecItemDelete(baseQuery(accountId) as CFDictionary)
    }

    private static func baseQuery(_ accountId: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountId.uuidString]
    }
}
