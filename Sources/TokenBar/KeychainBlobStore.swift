import Foundation
import Security
import TokenBarCore

/// Reads another app's generic-password Keychain item (used for Claude
/// Code's "Claude Code-credentials"). macOS may show an access prompt the first time; choose
/// "Always Allow" to avoid repeated prompts. Values are never logged.
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

    // Read-only on purpose. Updating an item that another app created can reset the item's
    // access list, after which the owning CLI (which reads through /usr/bin/security) is asked
    // for the Keychain password again. So TokenBar never renews a sign-in that lives in the
    // Keychain: the CLI renews it the next time it runs, and TokenBar picks the new one up.
    func checkWritable() throws {
        throw CredentialStoreError.notWritable
    }

    func write(_ data: Data) throws {
        throw CredentialStoreError.notWritable
    }
}

/// Tells whether a generic-password item exists, without reading its secret. Only attributes are
/// requested (no `kSecReturnData`), so macOS never shows a Keychain password prompt for this check.
/// Used by the Claude sign-in to notice the moment Claude Code has saved its credentials.
enum KeychainItemProbe {
    static func exists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
}
