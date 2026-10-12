// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AvatarImageDecode.swift.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct AvatarImageDecodeTests {
    static func main() {
        // Compressible images are tiny downloads but huge decoded bitmaps.
        let context = CGContext(data: nil, width: 4096, height: 2048,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        assert(CGImageDestinationFinalize(destination))
        assert(data.length < 4 * 1024 * 1024)
        let decoded = AvatarImageDecode.thumbnail(data as Data)!
        assert(decoded.width == 256 && decoded.height == 128, "Bound pixels while preserving aspect ratio")
        assert(decoded.bytesPerRow * decoded.height <= 256 * 256 * 4)
        assert(AvatarImageDecode.thumbnail(Data("not an image".utf8)) == nil)
        print("Avatar image decoding: compressed large image downsampled with bounded pixel memory")
    }
}
