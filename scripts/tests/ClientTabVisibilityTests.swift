// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientTabCustomization.swift.
import Foundation

@main
struct ClientTabVisibilityTests {
    static func main() {
        let order = ["home", "workspaces", "insights", "machines", "ssh"]
        let visible = ["home", "insights"]
        precondition(ClientTabVisibility.displayed(order: order, visible: visible, selected: "home") == visible)
        precondition(ClientTabVisibility.displayed(order: order, visible: visible, selected: "machines") == ["home", "insights", "machines"])
        precondition(ClientTabVisibility.displayed(order: order, visible: visible, selected: "workspaces") == ["home", "workspaces", "insights"])
        precondition(ClientTabVisibility.displayed(order: order, visible: visible, selected: "insights") == visible)
        precondition(ClientTabVisibility.displayed(order: order.reversed(), visible: ["insights"], selected: "workspaces") == ["insights", "workspaces"])
        precondition(visible == ["home", "insights"])
        print("ClientTabVisibilityTests passed")
    }
}
