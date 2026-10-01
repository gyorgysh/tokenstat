// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import CryptoKit
import Foundation

enum SSHKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519
    case ecdsaP256
    case ecdsaP256TouchID

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ed25519: return L10n.text("apple.sshkeyalgorithm.ed25519_default.119c85a7")
        case .ecdsaP256: return L10n.text("apple.sshkeyalgorithm.ecdsa_p_256.1053c845")
        case .ecdsaP256TouchID: return L10n.text("apple.sshkeyalgorithm.ecdsa_p_256_touch_id.5d348582")
        }
    }

    var explanation: String {
        switch self {
        case .ed25519: return L10n.text("apple.sshkeyalgorithm.the_default_for_new_keys_uses_the_same_key.ba47291e")
        case .ecdsaP256: return L10n.text("apple.sshkeyalgorithm.an_alternative_for_servers_that_require_ec.7056d8a0")
        case .ecdsaP256TouchID: return L10n.text("apple.sshkeyalgorithm.this_device_only_not_synced_to_vault_touch.f282e03a")
        }
    }

    /// Native generation avoids requiring a newer host protocol. The existing
    /// inspect method converts this PEM into the host's supported SSH format.
    static func makeP256PEM() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }
}
