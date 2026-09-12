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
        case .ed25519: return "Ed25519 (default)"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP256TouchID: return "ECDSA P-256 · Touch ID"
        }
    }

    var explanation: String {
        switch self {
        case .ed25519: return "The default for new keys. Uses the same key format as before."
        case .ecdsaP256: return "An alternative for servers that require ECDSA. This is a software key, not a Secure Enclave key."
        case .ecdsaP256TouchID: return "This device only. Not synced to vault. Touch ID is required to unlock this software key for a connection. This is not Secure Enclave signing. Changing enrolled fingerprints can make the key unusable, so keep another way to access your servers."
        }
    }

    /// Native generation avoids requiring a newer host protocol. The existing
    /// inspect method converts this PEM into the host's supported SSH format.
    static func makeP256PEM() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }
}
