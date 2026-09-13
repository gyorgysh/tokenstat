// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkflowCanvasCoordinates.swift.
import Foundation
import CoreGraphics

@main
struct WorkflowCanvasCoordinatesTests {
    static func main() {
        let origin = CGPoint(x: 200, y: 300)
        for zoom: CGFloat in [0.4, 1, 2.2] {
            let delta = CGSize(width: 80, height: -40)
            let point = WorkflowCanvasCoordinates.moved(from: origin, translation: delta, zoom: zoom)
            assert(abs((point.x - origin.x) * zoom - delta.width) < 0.0001)
            assert(abs((point.y - origin.y) * zoom - delta.height) < 0.0001)
            // Repeated pointer samples must not accumulate movement or snap back.
            assert(WorkflowCanvasCoordinates.moved(from: origin, translation: delta, zoom: zoom) == point)
        }
        assert(WorkflowCanvasCoordinates.moved(from: origin, translation: .zero, zoom: 1) == origin)
        assert(WorkflowCanvasCoordinates.moved(from: origin, translation: CGSize(width: CGFloat.infinity, height: 0), zoom: 1) == origin)
        assert(WorkflowCanvasCoordinates.moved(from: origin, translation: .zero, zoom: 0) == origin)
        assert(WorkflowCanvasCoordinates.clampedZoom(5) == WorkflowTouchViewport.maxZoom)
        assert(WorkflowCanvasCoordinates.clampedZoom(0.1) == WorkflowTouchViewport.minZoom)
        assert(WorkflowCanvasCoordinates.clampedZoom(.infinity) == 1)
        assert(WorkflowCanvasCoordinates.clampedZoom(CGFloat.nan) == 1)
        assert(WorkflowCanvasCoordinates.snapped(13) == 16)
        assert(WorkflowCanvasCoordinates.snapped(12) == 16)
        assert(WorkflowCanvasCoordinates.snapped(9) == 8)
        do {
            let empty = WorkflowTouchViewport.fit(nodeOrigins: [], canvasSize: CGSize(width: 800, height: 600))
            assert(empty.zoom == 1 && empty.pan == .zero)
            let tiny = WorkflowTouchViewport.fit(nodeOrigins: [], canvasSize: .zero)
            assert(tiny.zoom == 1 && tiny.pan == .zero)
        }
        do {
            // A blank draft already fits: fit never zooms in past 1.
            let single = WorkflowTouchViewport.fit(
                nodeOrigins: [CGPoint(x: 80, y: 120)],
                canvasSize: CGSize(width: 800, height: 600)
            )
            assert(single.zoom == 1)
            let placed = WorkflowTouchViewport.viewportPoint(
                for: CGPoint(x: 80, y: 120), pan: single.pan, zoom: single.zoom
            )
            assert(placed.x >= 0 && placed.y >= 0)
            assert(placed.x + WorkflowTouchViewport.cardWidth <= 800)
            assert(placed.y + WorkflowTouchViewport.cardHeight <= 600)
        }
        do {
            // A graph that fits at full width stays at zoom 1 with both
            // cards on screen.
            let pair = WorkflowTouchViewport.fit(
                nodeOrigins: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)],
                canvasSize: CGSize(width: 800, height: 600)
            )
            assert(pair.zoom == 1)
            for node in [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)] {
                let placed = WorkflowTouchViewport.viewportPoint(for: node, pan: pair.pan, zoom: pair.zoom)
                assert(placed.x >= -0.5 && placed.x + WorkflowTouchViewport.cardWidth <= 801)
            }
            // A very wide graph zooms out but never below the floor.
            let wide = WorkflowTouchViewport.fit(
                nodeOrigins: [CGPoint(x: 0, y: 0), CGPoint(x: 2000, y: 0)],
                canvasSize: CGSize(width: 800, height: 600)
            )
            assert(wide.zoom < 1 && wide.zoom >= WorkflowTouchViewport.minZoom)
            // Same graph, smaller canvas: zoom-out only, never below the floor.
            let small = WorkflowTouchViewport.fit(
                nodeOrigins: [CGPoint(x: 0, y: 0), CGPoint(x: 2000, y: 0)],
                canvasSize: CGSize(width: 200, height: 150)
            )
            assert(small.zoom == WorkflowTouchViewport.minZoom)
        }
        do {
            let pan = CGSize(width: 10, height: 20)
            let placed = WorkflowTouchViewport.viewportPoint(for: CGPoint(x: 100, y: 100), pan: pan, zoom: 2)
            assert(placed == CGPoint(x: 210, y: 220))
            assert(WorkflowTouchViewport.hitsPort(touch: placed, port: placed))
            assert(!WorkflowTouchViewport.hitsPort(touch: CGPoint(x: 0, y: 0), port: placed))
            assert(!WorkflowTouchViewport.hitsPort(
                touch: CGPoint(x: CGFloat.nan, y: 0), port: placed
            ))
        }
        print("Workflow canvas coordinate tests passed")
    }
}
