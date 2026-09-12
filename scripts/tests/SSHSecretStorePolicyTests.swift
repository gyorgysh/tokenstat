// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHSecretStore.swift and SSHKeyAlgorithm.swift.
import Foundation

@main struct SSHSecretStorePolicyTests {
    static func main() throws {
        assert(SSHKeyAlgorithm.allCases.first == .ed25519)
        assert(SSHKeyAlgorithm.ecdsaP256TouchID.explanation.contains("Not synced to vault"))
        assert(SSHSecretStore.requiresBiometrics("keychain-biometric:test"))
        assert(!SSHSecretStore.requiresBiometrics("keychain:test"))
        assert(!SSHSecretStore.requiresBiometrics("agent:test"))
        // Background reads must reject before reaching Keychain. These tests
        // never create credentials or display an authentication prompt.
        do {
            _ = try SSHSecretStore.load(reference: "keychain-biometric:test")
            assertionFailure("A background read accepted a biometric reference")
        } catch {}
        print("SSH secret policy tests passed without Keychain access")
    }
}
