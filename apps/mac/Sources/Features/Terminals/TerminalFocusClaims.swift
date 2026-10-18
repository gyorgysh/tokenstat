// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A retained, hidden terminal pane may release only its own polling claim.
struct TerminalFocusClaims {
    private var claims: [UUID: Set<String>] = [:]
    mutating func update(owner: UUID, ids: Set<String>) {
        claims[owner] = ids.isEmpty ? nil : ids
    }
    var visibleIDs: Set<String> { claims.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
}
