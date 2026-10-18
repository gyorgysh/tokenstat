// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreGraphics

/// Both viewer sizes fit inside the owning window, including on small displays.
enum ChatImageViewerGeometry {
    static func size(available: CGSize, enlarged: Bool) -> CGSize {
        let width = available.width.isFinite ? max(1, available.width) : 1040
        let height = available.height.isFinite ? max(1, available.height) : 780
        if enlarged { return CGSize(width: width, height: height) }
        return CGSize(width: min(width, max(min(480, width), min(1040, width * 0.84))),
                      height: min(height, max(min(400, height), min(780, height * 0.84))))
    }
}
