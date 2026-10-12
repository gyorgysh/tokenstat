// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import ImageIO

/// Bound decoded memory, not only the compressed download size. A small PNG
/// can contain millions of pixels even though an avatar needs only a thumbnail.
enum AvatarImageDecode {
    static let maxPixelSize = 256

    static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
