// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import LocalAuthentication
import Security

/// A device-only password wrapper. The Keychain, not a UI authentication flag,
/// enforces biometric access. Changing enrolled biometrics invalidates the item.
enum SSHVaultBiometrics {
    static var name: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        default: return nil
        }
    }

    static func accountKey() async throws -> String {
        let account = try await Bridge.account()
        guard account.signedIn, let handle = account.handle, let machine = account.thisMachineID else {
            throw failure("Sign in before enabling biometric vault unlock.")
        }
        return [account.host, handle, machine].joined(separator: "\n")
    }

    private static func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.tokenstat.ssh-vault.biometrics",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func contains(account: String) -> Bool {
        var query = query(account)
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func save(password: String, account: String) async throws {
        try await Task.detached {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
                throw error?.takeRetainedValue() as Error? ?? failure("Biometric unlock is unavailable.")
            }
            try remove(account: account)
            var query = query(account)
            query[kSecAttrAccessControl as String] = access
            query[kSecValueData as String] = Data(password.utf8)
            let result = SecItemAdd(query as CFDictionary, nil)
            guard result == errSecSuccess else {
                if result == errSecMissingEntitlement {
                    throw failure("This build is missing the signing configuration required for biometric unlock. Use your vault password until the app is rebuilt with its Keychain entitlement and provisioning profile. (Keychain \(result))")
                }
                let reason = SecCopyErrorMessageString(result, nil) as String? ?? "Unknown Keychain error"
                throw failure("Could not enable biometric unlock: \(reason) (Keychain \(result)). Your vault password still works.")
            }
        }.value
    }

    static func load(account: String) async throws -> String {
        try await Task.detached {
            let context = LAContext()
            context.localizedReason = "Unlock your SSH vault"
            context.localizedFallbackTitle = ""
            defer { context.invalidate() }
            var query = query(account)
            query[kSecUseAuthenticationContext as String] = context
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw failure("Biometric unlock did not complete. Try again or enter your vault password.")
            }
            return password
        }.value
    }

    static func remove(account: String? = nil) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        // Unsigned/ad-hoc development builds cannot access the data protection
        // Keychain. They cannot enroll a password either; ordinary sign-out,
        // password changes and vault deletion must remain usable in those builds.
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw failure("Could not remove the saved biometric vault password. Try again.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SSHVaultBiometrics", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
