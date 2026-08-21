// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Security

/// Device-local SSH secrets. Metadata stores only the `keychain:<id>` reference.
enum SSHSecretStore {
    private static let service = "ai.tokenstat.ssh"

    static func store(_ secret: String, id: String) throws -> String {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return "keychain:\(id)"
    }

    static func load(reference: String) throws -> String {
        guard reference.hasPrefix("keychain:") else {
            throw NSError(domain: "SSHSecretStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown SSH secret reference"])
        }
        let id = String(reference.dropFirst("keychain:".count))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return secret
    }

    static func delete(reference: String) {
        guard reference.hasPrefix("keychain:") else { return }
        let id = String(reference.dropFirst("keychain:".count))
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ] as CFDictionary)
    }
}
