// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import CoreGraphics

/// Pointer geometry and the short exit grace shared by sidebar hover cards.
/// Sampling can advance dismissal even when AppKit delivers no mouse events.
struct SidebarHoverState {
    private var leftAt: TimeInterval?

    mutating func shouldClose(pointerInside: Bool, at time: TimeInterval) -> Bool {
        if pointerInside {
            leftAt = nil
            return false
        }
        guard let leftAt else {
            self.leftAt = time
            return false
        }
        return time - leftAt >= 0.22
    }

    static func contains(_ point: CGPoint, row: CGRect?, card: CGRect?) -> Bool {
        if let row {
            if row.insetBy(dx: -4, dy: -4).contains(point) { return true }
            if let card {
                // The popover can flip to the left at a screen edge. The
                // crossing corridor stays within the row's vertical band.
                let left = card.midX >= row.midX ? row.maxX : card.maxX
                let right = card.midX >= row.midX ? card.minX : row.minX
                let bottom = max(row.minY, card.minY)
                let top = min(row.maxY, card.maxY)
                if right >= left, top > bottom {
                    let bridge = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                    if bridge.insetBy(dx: -4, dy: -4).contains(point) { return true }
                }
            }
        }
        return card?.insetBy(dx: -4, dy: -4).contains(point) == true
    }
}
