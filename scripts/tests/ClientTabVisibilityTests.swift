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
        // A sixth destination takes the last slot rather than making iOS add More.
        let full = ["home", "workspaces", "insights", "machines", "ssh"]
        let all = full + ["team"]
        precondition(ClientTabVisibility.displayed(order: all, visible: full, selected: "team", limit: 5) == ["home", "workspaces", "insights", "machines", "team"])
        precondition(ClientTabVisibility.displayed(order: all, visible: full, selected: "home", limit: 5) == full)
        precondition(ClientTabVisibility.displayed(order: all, visible: ["home"], selected: "team", limit: 5) == ["home", "team"])
        print("ClientTabVisibilityTests passed")
    }
}
