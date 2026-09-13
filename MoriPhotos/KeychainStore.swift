import Foundation
import Security

enum KeychainStore {
    private static let service = "dev.kylon.MoriPhotos.nas"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "connection"]
    }
    static func save(_ connection: SavedNASConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    static func load() throws -> SavedNASConnection? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { return nil }
        return try SavedNASConnection.decode(data)
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    static func setBackgroundAccess(_ enabled: Bool) throws {
        // Background photo backup needs the saved connection after the first device unlock.
        // The item remains device-only and is never synchronized to iCloud Keychain.
        let accessibility = enabled ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try check(SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: accessibility] as CFDictionary))
    }
    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法访问系统钥匙串（\(status)）。"])
        }
    }
}
