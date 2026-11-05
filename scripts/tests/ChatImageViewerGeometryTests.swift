// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatImageViewerGeometry.swift using swiftc -parse-as-library, then run.
import Foundation
import CoreGraphics

@main enum ChatImageViewerGeometryTests {
    static func main() {
        for size in [CGSize(width: 1248, height: 780), CGSize(width: 800, height: 580),
                     CGSize(width: 320, height: 240), CGSize(width: 2400, height: 1400)] {
            let normal = ChatImageViewerGeometry.size(available: size, enlarged: false)
            let enlarged = ChatImageViewerGeometry.size(available: size, enlarged: true)
            precondition(normal.width <= size.width && normal.height <= size.height)
            precondition(enlarged == size && enlarged.width >= normal.width && enlarged.height >= normal.height)
            if size.width >= 800 { precondition(enlarged.width > normal.width && enlarged.height > normal.height) }
        }
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: CGFloat.nan)] {
            let resolved = ChatImageViewerGeometry.size(available: size, enlarged: true)
            precondition(resolved.width.isFinite && resolved.width > 0 && resolved.height.isFinite && resolved.height > 0)
        }
        let viewport = CGSize(width: 600, height: 400)
        precondition(ChatImageViewerGeometry.fit(image: CGSize(width: 1000, height: 500), viewport: viewport) == CGSize(width: 600, height: 300))
        precondition(ChatImageViewerGeometry.fit(image: CGSize(width: 500, height: 1000), viewport: viewport) == CGSize(width: 200, height: 400))
        precondition(ChatImageViewerGeometry.fit(image: .zero, viewport: viewport) == .zero)
        precondition(ChatImageViewerGeometry.fit(image: viewport, viewport: CGSize(width: CGFloat.infinity, height: 400)) == .zero)
        precondition(ChatImageViewerGeometry.swipe(x: -120, y: 10, width: 600) == 1)
        precondition(ChatImageViewerGeometry.swipe(x: 120, y: 10, width: 600) == -1)
        precondition(ChatImageViewerGeometry.swipe(x: 100, y: 0, width: 600) == 0)
        precondition(ChatImageViewerGeometry.swipe(x: 120, y: 100, width: 600) == 0)
        precondition(ChatImageViewerGeometry.swipe(x: 40, y: 0, width: 100) == 0)
        precondition(ChatImageViewerGeometry.swipe(x: .nan, y: 0, width: 600) == 0)
        precondition(ChatImageViewerGeometry.swipe(x: 120, y: 0, width: 0) == 0)
        print("ChatImageViewerGeometryTests passed")
    }
}
