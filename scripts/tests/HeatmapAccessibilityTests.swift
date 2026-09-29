// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HeatmapAccessibility.swift.
import AppKit

struct HeatCell: Hashable {
    var date: String
    var value: UInt64
    var locked = false
    var isLocked: Bool { locked }
}
func formatSpend(_ value: UInt64) -> String { "$\(value)" }

@main struct HeatmapAccessibilityTests {
    @MainActor static func main() {
        let day = HeatCell(date: "2026-01-01", value: 3)
        let locked = HeatCell(date: "2025-01-01", value: 1, locked: true)
        let host = HeatmapAccessibilityHost()
        var selected: HeatCell?
        host.onSelect = { selected = $0 }
        host.update(rows: [[day, nil, locked]])
        let children = host.accessibilityChildren() ?? []
        assert(children.count == 1, "Blank and locked days do not expose actions")
        let button = children[0] as! HeatmapAccessibilityDay
        assert(button.isAccessibilityEnabled())
        assert(button.isAccessibilitySelectorAllowed(#selector(NSAccessibilityProtocol.accessibilityPerformPress)))
        assert(button.accessibilityPerformPress() && selected == day)
        host.update(rows: [[day, nil, locked]])
        assert((host.accessibilityChildren()?.first as AnyObject?) === button, "A geometry-only update must reuse day elements")
        selected = nil
        host.onSelect = { selected = HeatCell(date: "updated action", value: $0.value) }
        assert(button.accessibilityPerformPress() && selected?.date == "updated action", "Reused elements must use the latest action")
        host.onSelect = nil
        assert(!button.isAccessibilityEnabled() && !button.accessibilityPerformPress())
        weak var released: HeatmapAccessibilityHost?
        var retainedChild: HeatmapAccessibilityDay?
        autoreleasepool {
            let temporary = HeatmapAccessibilityHost()
            temporary.update(rows: [[day]])
            retainedChild = temporary.accessibilityChildren()?.first as? HeatmapAccessibilityDay
            released = temporary
        }
        assert(released == nil && retainedChild?.owner == nil, "Virtual children must not retain their view")
        print("Heatmap accessibility: actions, stable elements, locked days and lifetime passed")
    }
}
