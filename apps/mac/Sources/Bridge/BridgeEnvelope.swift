// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

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
