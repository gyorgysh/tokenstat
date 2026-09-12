// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import CoreGraphics

/// Convert fixed viewport movement to graph coordinates, independently of the
/// moving card's frame. Pan is already measured in viewport points.
enum WorkflowCanvasCoordinates {
    static func moved(from origin: CGPoint, translation: CGSize, zoom: CGFloat) -> CGPoint {
        guard zoom.isFinite, zoom > 0,
              translation.width.isFinite, translation.height.isFinite else { return origin }
        let point = CGPoint(x: origin.x + translation.width / zoom,
                            y: origin.y + translation.height / zoom)
        return point.x.isFinite && point.y.isFinite ? point : origin
    }
}
