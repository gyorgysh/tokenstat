// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHVaultSyncedKey.swift.
import Foundation

@main struct SSHVaultSyncedKeyTests {
    static func main() throws {
        let old = Data(#"{"id":"key","label":"Old key","algorithm":"ed25519","publicKey":"public","privateKey":"private","hardwareBacked":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SSHVaultSyncedKey.self, from: old)
        assert(decoded.updatedMs == 0 && decoded.privateKey == "private")
        let current = SSHVaultSyncedKey(id: "key", label: "Updated", algorithm: "ed25519",
                                      publicKey: "public", privateKey: "private", hardwareBacked: false,
                                      updatedMs: 42)
        let roundTrip = try JSONDecoder().decode(SSHVaultSyncedKey.self, from: JSONEncoder().encode(current))
        assert(roundTrip.updatedMs == 42 && roundTrip.label == "Updated")
        print("SSH vault keys: legacy zero stamp and current roundtrip passed")
    }
}
