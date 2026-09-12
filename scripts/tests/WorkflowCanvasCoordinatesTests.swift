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
        print("Workflow canvas coordinate tests passed")
    }
}
