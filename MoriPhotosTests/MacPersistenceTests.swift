#if targetEnvironment(macCatalyst)
import XCTest
import Security
@testable import MoriPhotos

final class MacPersistenceTests: XCTestCase {
    func testSignedMacProcessCanPersistDeviceLocalSecret() throws {
        let service = "dev.kylon.MoriPhotos.tests." + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "test"]
        defer { SecItemDelete(query as CFDictionary) }
        var item = query
        item[kSecValueData as String] = Data("local-test-value".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        var read = query; read[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, Data("local-test-value".utf8))
    }
}
#endif
