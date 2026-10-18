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
        print("ChatImageViewerGeometryTests passed")
    }
}
