// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TerminalFocusClaims.swift using swiftc -parse-as-library, then run.
import Foundation

@main enum TerminalFocusClaimsTests {
    static func main() {
        var claims = TerminalFocusClaims()
        let workspace = UUID(), companion = UUID()
        claims.update(owner: workspace, ids: ["shell", "agent"])
        claims.update(owner: companion, ids: [])
        precondition(claims.visibleIDs == ["shell", "agent"], "hidden companion cannot clear the workspace")
        claims.update(owner: companion, ids: ["shell"])
        claims.update(owner: workspace, ids: [])
        precondition(claims.visibleIDs == ["shell"], "late workspace teardown cannot clear the visible companion")
        claims.update(owner: companion, ids: [])
        precondition(claims.visibleIDs.isEmpty, "hidden terminals must leave the foreground polling rate")
        print("TerminalFocusClaimsTests passed")
    }
}
