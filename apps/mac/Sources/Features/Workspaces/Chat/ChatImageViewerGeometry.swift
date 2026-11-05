// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreGraphics

/// Both viewer sizes fit inside the owning window, including on small displays.
enum ChatImageViewerGeometry {
    static func fit(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0,
              image.width.isFinite, image.height.isFinite, viewport.width.isFinite, viewport.height.isFinite else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    static func swipe(x: CGFloat, y: CGFloat, width: CGFloat) -> Int {
        guard x.isFinite, y.isFinite, width.isFinite, width > 0,
              abs(x) >= max(48, width * 0.18), abs(x) > abs(y) * 1.3 else { return 0 }
        return x < 0 ? 1 : -1
    }
    static func size(available: CGSize, enlarged: Bool) -> CGSize {
        let width = available.width.isFinite ? max(1, available.width) : 1040
        let height = available.height.isFinite ? max(1, available.height) : 780
        if enlarged { return CGSize(width: width, height: height) }
        return CGSize(width: min(width, max(min(480, width), min(1040, width * 0.84))),
                      height: min(height, max(min(400, height), min(780, height * 0.84))))
    }
}
