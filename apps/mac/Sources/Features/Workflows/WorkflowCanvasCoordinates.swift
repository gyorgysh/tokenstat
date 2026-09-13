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

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(WorkflowTouchViewport.maxZoom, max(WorkflowTouchViewport.minZoom, zoom))
    }

    static func snapped(_ value: Double, step: Double = 8) -> Double {
        guard value.isFinite, step.isFinite, step > 0 else { return value }
        return (value / step).rounded() * step
    }
}

/// Touch canvas viewport: pan, zoom, fit and port hit-testing without any
/// view code, so the math stays covered by standalone tests.
///
/// The Mac canvas and the iPad touch canvas share card size and the
/// fit-only-zooms-out rule: a blank draft opens at its own size, never
/// magnified into a wall of one node.
enum WorkflowTouchViewport {
    static let cardWidth: CGFloat = 228
    static let cardHeight: CGFloat = 120
    static let minZoom: CGFloat = 0.4
    static let maxZoom: CGFloat = 2.2
    static let pad: CGFloat = 64
    /// Finger-sized port targets stay generous even when the canvas is small.
    static let portHitRadius: CGFloat = 22

    struct Fit: Equatable {
        var zoom: CGFloat
        var pan: CGSize
    }

    /// Bounding-box fit over node top-left points. Empty input resets.
    static func fit(nodeOrigins: [CGPoint], canvasSize: CGSize) -> Fit {
        guard !nodeOrigins.isEmpty, canvasSize.width > 1, canvasSize.height > 1 else {
            return Fit(zoom: 1, pan: .zero)
        }
        let minX = nodeOrigins.map(\.x).min() ?? 0
        let minY = nodeOrigins.map(\.y).min() ?? 0
        let maxX = nodeOrigins.map { $0.x + cardWidth }.max() ?? cardWidth
        let maxY = nodeOrigins.map { $0.y + cardHeight }.max() ?? cardHeight
        let width = max(maxX - minX, 1) + pad * 2
        let height = max(maxY - minY, 1) + pad * 2
        let zoom = min(1, max(minZoom, min(canvasSize.width / width, canvasSize.height / height)))
        let pan = CGSize(
            width: (canvasSize.width - width * zoom) / 2 - (minX - pad) * zoom,
            height: (canvasSize.height - height * zoom) / 2 - (minY - pad) * zoom
        )
        return Fit(zoom: zoom, pan: pan)
    }

    /// Viewport point of a node top-left under the current pan/zoom.
    static func viewportPoint(for origin: CGPoint, pan: CGSize, zoom: CGFloat) -> CGPoint {
        CGPoint(x: origin.x * zoom + pan.width, y: origin.y * zoom + pan.height)
    }

    static func hitsPort(touch: CGPoint, port: CGPoint, radius: CGFloat = portHitRadius) -> Bool {
        guard touch.x.isFinite, touch.y.isFinite, port.x.isFinite, port.y.isFinite else { return false }
        let dx = touch.x - port.x
        let dy = touch.y - port.y
        return (dx * dx + dy * dy).squareRoot() < radius
    }
}
