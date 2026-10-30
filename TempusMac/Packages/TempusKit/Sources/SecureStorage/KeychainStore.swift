import Foundation
import Security

public enum SecretStoreError: Error, Sendable, Equatable {
    /// The Security framework returned this status.
    case unexpectedStatus(OSStatus)
    /// The store returned something that is not data.
    case unexpectedData
    case encodingFailed
    case decodingFailed
}

/// Somewhere to keep secrets. `KeychainStore` in the app, an in-memory store in tests.
public protocol SecretStore: Sendable {
    func data(for key: String) throws(SecretStoreError) -> Data?
    func set(_ data: Data, for key: String) throws(SecretStoreError)
    /// Succeeds when there was nothing to remove.
    func removeData(for key: String) throws(SecretStoreError)
}

/// Generic-password items in the user's keychain, one per key, under `service`.
///
/// Uses the file-based keychain, which works for ad-hoc and Developer ID signed builds alike;
/// the data-protection keychain would need a team-signed application identifier. Items are
/// protected by the keychain's lock and the item's access list (the app that created it), not
/// by an accessibility class, which the file-based keychain ignores.
///
/// Calls block on the Security framework, so make them off the main actor.
public struct KeychainStore: SecretStore {
    public static let appService = "io.github.unrefundable.TempusMac"

    public let service: String

    public init(service: String = appService) {
        self.service = service
    }

    public func data(for key: String) throws(SecretStoreError) -> Data? {
        var query = itemQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw .unexpectedStatus(status)
        }
    }

    public func set(_ data: Data, for key: String) throws(SecretStoreError) {
        let status = update(data, for: key)
        guard status == errSecItemNotFound else {
            guard status == errSecSuccess else { throw .unexpectedStatus(status) }
            return
        }
        var item = itemQuery(key)
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        // Another writer may have added the item since the update found nothing.
        let final = added == errSecDuplicateItem ? update(data, for: key) : added
        guard final == errSecSuccess else { throw .unexpectedStatus(final) }
    }

    private func update(_ data: Data, for key: String) -> OSStatus {
        SecItemUpdate(itemQuery(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    public func removeData(for key: String) throws(SecretStoreError) {
        let status = SecItemDelete(itemQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .unexpectedStatus(status) }
    }

    private func itemQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
