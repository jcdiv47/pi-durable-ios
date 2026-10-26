import Foundation
import Security

/// Provider API keys in the Keychain, one generic-password item per provider. Readable after the
/// first unlock so background runs can use them; never synced off the device.
public struct KeychainKeys: ProviderKeySource {
    public let service: String
    /// Keychain sharing group, or nil for the app's default (first) group.
    public let accessGroup: String?

    public init(service: String = "dev.jcdiv47.pidurable.provider-keys", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func apiKey(for provider: String) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func hasKey(for provider: String) -> Bool { apiKey(for: provider)?.isEmpty == false }

    public func setKey(_ key: String, for provider: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(baseQuery(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(provider)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func removeKey(for provider: String) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func baseQuery(_ provider: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw JSRuntimeError("Keychain: \(message)")
        }
    }
}
