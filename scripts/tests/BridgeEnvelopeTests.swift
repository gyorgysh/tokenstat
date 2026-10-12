// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with BridgeEnvelope.swift.
import Foundation

@main struct BridgeEnvelopeTests {
    static func main() throws {
        struct Receipt: Decodable { let operationId: String }
        let empty = Data(#"{"ok":true,"result":null}"#.utf8)
        let envelope = try JSONDecoder().decode(BridgeEnvelope<Receipt?>.self, from: empty)
        guard let result = envelope.result else { fatalError("A successful null receipt was erased") }
        assert(envelope.ok && result == nil)
        let missing = try JSONDecoder().decode(BridgeEnvelope<Receipt?>.self, from: Data(#"{"ok":true}"#.utf8))
        assert(missing.result == nil)
        let value = try JSONDecoder().decode(BridgeEnvelope<Receipt?>.self,
            from: Data(#"{"ok":true,"result":{"operationId":"operation"}}"#.utf8))
        assert(value.result??.operationId == "operation")
        let failure = try JSONDecoder().decode(BridgeEnvelope<Receipt>.self,
            from: Data(#"{"ok":false,"result":null,"error":{"code":"denied","message":"No"}}"#.utf8))
        assert(!failure.ok && failure.error?.code == "denied")
        do {
            _ = try JSONDecoder().decode(BridgeEnvelope<Receipt>.self, from: empty)
            fatalError("A required result accepted null")
        } catch is DecodingError {}
        print("Bridge envelopes: null receipts, missing results, values and failure envelopes passed")
    }
}
