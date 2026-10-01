// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SidebarHoverState.swift.
import Foundation
import CoreGraphics

@main enum SidebarHoverStateTests {
    static func main() {
        let row = CGRect(x: 0, y: 100, width: 200, height: 30)
        let rightCard = CGRect(x: 214, y: 0, width: 340, height: 400)
        let leftCard = CGRect(x: -354, y: 0, width: 340, height: 400)

        // A pointer can leave the row, cross the arrow gap and read the card.
        for point in [CGPoint(x: 100, y: 115), CGPoint(x: 208, y: 115), CGPoint(x: 300, y: 250)] {
            precondition(SidebarHoverState.contains(point, row: row, card: rightCard))
        }
        precondition(SidebarHoverState.contains(CGPoint(x: -8, y: 115), row: row, card: leftCard))
        precondition(SidebarHoverState.contains(CGPoint(x: -200, y: 250), row: row, card: leftCard))
        // Empty space beside a tall card must not keep it open.
        precondition(!SidebarHoverState.contains(CGPoint(x: 208, y: 250), row: row, card: rightCard))
        precondition(!SidebarHoverState.contains(CGPoint(x: -8, y: 250), row: row, card: leftCard))
        precondition(!SidebarHoverState.contains(CGPoint(x: 600, y: 250), row: row, card: rightCard))
        precondition(!SidebarHoverState.contains(CGPoint(x: 300, y: 250), row: row, card: nil))
        precondition(!SidebarHoverState.contains(.zero, row: nil, card: nil))

        // Repeated samples outside do not postpone dismissal. No mouse event
        // is needed after the pointer stops moving outside the card.
        var state = SidebarHoverState()
        precondition(!state.shouldClose(pointerInside: true, at: 10))
        precondition(!state.shouldClose(pointerInside: false, at: 11))
        precondition(!state.shouldClose(pointerInside: false, at: 11.1))
        precondition(state.shouldClose(pointerInside: false, at: 11.24))

        // Returning during the grace period cancels that departure; the next
        // exit gets its own grace rather than inheriting the earlier deadline.
        state = SidebarHoverState()
        precondition(!state.shouldClose(pointerInside: false, at: 20))
        precondition(!state.shouldClose(pointerInside: true, at: 20.15))
        precondition(!state.shouldClose(pointerInside: false, at: 20.3))
        precondition(!state.shouldClose(pointerInside: false, at: 20.45))
        precondition(state.shouldClose(pointerInside: false, at: 20.6))
        print("Sidebar hover: row/card crossings, flipped popovers, stationary exits and re-entry passed")
    }
}
