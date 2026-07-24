import Foundation
import Security

/// Where secret bytes live. The real implementation is the Keychain; the
/// protocol keeps key management testable where the real Keychain is
/// unavailable or flaky (CI without a simulator keychain, previews).
protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    /// Every stored secret keyed by account. The Notification Key lookup
    /// selects by a derived key id, so it must be able to walk all entries.
    func readAll() throws -> [String: Data]
    func write(_ secret: Data, account: String) throws
    func removeSecret(account: String) throws
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain items under one service. Items are scoped to
/// this device only (`ThisDeviceOnly`): the device key must never migrate to
/// another device via backup or iCloud Keychain.
///
/// An optional access group shares the items with other targets of this app
/// — the Notification Service Extension reads Notification Keys through the
/// app-group access group, which iOS accepts in `kSecAttrAccessGroup`
/// without the team id prefix.
struct KeychainSecretStore: SecretStore {
    let service: String
    var accessGroup: String?

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func readAll() throws -> [String: Data] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            var secrets: [String: Data] = [:]
            for item in items as? [[String: Any]] ?? [] {
                guard let account = item[kSecAttrAccount as String] as? String,
                    let data = item[kSecValueData as String] as? Data
                else { continue }
                secrets[account] = data
            }
            return secrets
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func write(_ secret: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: secret]
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removeSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
