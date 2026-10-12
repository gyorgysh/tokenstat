// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A key on its way through the vault, private half included. This shape exists
/// only inside an encrypted record and is never written to disk in the clear.
struct SSHVaultSyncedKey: Codable {
    var id: String
    var label: String
    var algorithm: String
    var publicKey: String
    var privateKey: String
    var hardwareBacked: Bool
    /// Missing on records written by a build without merge stamps, which reads
    /// as 0 and loses to anything stamped.
    var updatedMs: Int64 = 0
}

extension SSHVaultSyncedKey {
    private enum CodingKeys: String, CodingKey {
        case id, label, algorithm, publicKey, privateKey, hardwareBacked, updatedMs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        algorithm = try values.decode(String.self, forKey: .algorithm)
        publicKey = try values.decode(String.self, forKey: .publicKey)
        privateKey = try values.decode(String.self, forKey: .privateKey)
        hardwareBacked = try values.decode(Bool.self, forKey: .hardwareBacked)
        updatedMs = try values.decodeIfPresent(Int64.self, forKey: .updatedMs) ?? 0
    }
}
