// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Keep an explicit null result distinct from a missing result. T may itself
/// be Optional for receipts and lookups; decodeIfPresent would erase that
/// valid answer before the bridge can unwrap it.
struct BridgeEnvelope<T: Decodable>: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
    }
    let ok: Bool
    let result: T?
    let error: Failure?

    private enum CodingKeys: String, CodingKey { case ok, result, error }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decode(Bool.self, forKey: .ok)
        error = try values.decodeIfPresent(Failure.self, forKey: .error)
        if ok, values.contains(.result) {
            result = .some(try values.decode(T.self, forKey: .result))
        } else {
            result = nil
        }
    }
}
