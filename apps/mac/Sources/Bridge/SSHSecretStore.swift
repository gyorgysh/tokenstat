// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Security
import LocalAuthentication

/// Device-local SSH secrets. Metadata stores only the `keychain:<id>` reference.
enum SSHSecretStore {
    private static let service = "ai.tokenstat.ssh"

    static func requiresBiometrics(_ reference: String) -> Bool {
        reference.hasPrefix("keychain-biometric:")
    }

    static func store(_ secret: String, id: String, biometric: Bool = false) throws -> String {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: biometric ? service + ".biometric" : service,
            kSecAttrAccount as String: id,
        ]
        var add = query
        add[kSecValueData as String] = data
        if biometric {
            let context = LAContext()
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil),
                  context.biometryType == .touchID else {
                throw NSError(domain: "SSHSecretStore", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "Touch ID is unavailable. Set it up or unlock this device, then try again."])
            }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
                throw error?.takeRetainedValue() as Error? ?? biometricError()
            }
            add[kSecUseDataProtectionKeychain as String] = true
            add[kSecAttrAccessControl as String] = access
            add[kSecAttrSynchronizable as String] = false
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem && !biometric {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            if biometric && status == errSecMissingEntitlement {
                throw NSError(domain: "SSHSecretStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                    "This build cannot save Touch ID keys because its Keychain signing entitlement is missing. Use a properly signed build. Existing keys are unchanged."])
            }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return "\(biometric ? "keychain-biometric" : "keychain"):\(id)"
    }

    /// Only an explicit connection path may prompt. Background sync calls
    /// `load`, which cannot unlock a biometric key.
    static func loadForUse(reference: String) async throws -> String {
        guard requiresBiometrics(reference) else { return try load(reference: reference) }
        try Task.checkCancellation()
        let context = LAContext()
        context.localizedReason = "Use your SSH key to connect"
        context.localizedFallbackTitle = ""
        defer { context.invalidate() }
        let secret = try await withTaskCancellationHandler {
            try await Task.detached {
                var query = biometricQuery(reference)
                query[kSecUseAuthenticationContext as String] = context
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data,
                      let value = String(data: data, encoding: .utf8) else { throw biometricError() }
                return value
            }.value
        } onCancel: {
            context.invalidate()
        }
        try Task.checkCancellation()
        return secret
    }

    static func contains(reference: String) -> Bool {
        guard requiresBiometrics(reference) else { return (try? load(reference: reference)) != nil }
        var query = biometricQuery(reference)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func biometricQuery(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service + ".biometric",
         kSecAttrAccount as String: String(reference.dropFirst("keychain-biometric:".count)),
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    private static func biometricError() -> NSError {
        NSError(domain: "SSHSecretStore", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "Touch ID could not unlock this key. Try again. If your enrolled fingerprints changed, create a new key and authorize it on your servers."])
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
        if requiresBiometrics(reference) {
            SecItemDelete(biometricQuery(reference) as CFDictionary)
            return
        }
        guard reference.hasPrefix("keychain:") else { return }
        let id = String(reference.dropFirst("keychain:".count))
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ] as CFDictionary)
    }
}
