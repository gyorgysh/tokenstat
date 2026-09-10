// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Keep surviving destinations in place while a person is selecting a row.
/// Missing destinations disappear immediately. Accepting an update adopts the
/// new ranking, including newly arrived hits and changed message anchors.
enum WorkSearchResultOrder {
    static func destination(_ reference: WorkReference) -> WorkReference {
        var value = reference
        value.anchor = nil
        return value
    }

    static func retained(previous: [WorkReference], incoming: [WorkReference]) -> [WorkReference] {
        let fresh = Dictionary(incoming.map { (destination($0), $0) }, uniquingKeysWith: { first, _ in first })
        return previous.compactMap { fresh[destination($0)] }
    }
}
