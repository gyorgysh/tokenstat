// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct SSHVaultSyncedKey: Codable {
    var id: String
    var label: String
    var algorithm: String
    var publicKey: String
    var privateKey: String
    var hardwareBacked: Bool
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
