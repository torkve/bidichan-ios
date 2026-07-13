import Foundation
import Security

/// Minimal generic-password Keychain wrapper for secrets (the PSK).
///
/// The app and the extension declare the same single `keychain-access-group`
/// entitlement, so items added by one are readable by the other without
/// specifying `kSecAttrAccessGroup` (the default group is that shared group).
/// Items use `AfterFirstUnlock` so the extension can read the PSK when it is
/// launched in the background after the device has been unlocked once.
public enum Keychain {
    public enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    public static func set(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BidichanConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BidichanConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: BidichanConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
