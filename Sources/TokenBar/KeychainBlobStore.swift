import Foundation
import Security
import TokenBarCore

/// Reads and updates another app's generic-password Keychain item in place (used for Claude
/// Code's "Claude Code-credentials"). macOS may show an access prompt the first time; choose
/// "始终允许" to avoid repeated prompts. Values are never logged.
struct KeychainBlobStore: CredentialBlobStore {
    let service: String
    var label: String { "keychain:\(service)" }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service]
    }

    func read() throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialStoreError.unreadable }
            return data
        case errSecItemNotFound:
            throw CredentialStoreError.notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw CredentialStoreError.denied
        default:
            throw CredentialStoreError.unreadable
        }
    }

    /// Re-writes the current value unchanged. This asks the OS for exactly the permission the
    /// real write-back needs, before a rotating refresh token is spent.
    func checkWritable() throws {
        let current = try read()
        try update(current)
    }

    func write(_ data: Data) throws {
        try update(data)
    }

    private func update(_ data: Data) throws {
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw CredentialStoreError.denied
        default: throw CredentialStoreError.notWritable
        }
    }
}
