// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatImageLayout.swift.
import Foundation
import ImageIO

@main struct ChatImageLayoutTests {
    static func main() async throws {
        let source = [ChatImageDimensions(width: 608, height: 286),
            ChatImageDimensions(width: 340, height: 428), ChatImageDimensions(width: 1520, height: 1222)]
        let wide = ChatImageGalleryGeometry(width: 760, dimensions: source)
        precondition(wide.frames.count == 3 && wide.frames.allSatisfy { $0.minY == 0 })
        precondition(abs(wide.size.width - 640) < 0.01 && (150...152).contains(wide.size.height),
            "The real mixed-aspect set must use one balanced row, capped at transcript width")
        precondition(abs(wide.frames[0].width / wide.frames[1].width - source[0].aspect / source[1].aspect) < 0.001)
        for width: CGFloat in [100, 280, 320, 640, 1000] {
            for count in 1...9 {
                let dimensions = (0..<count).map { $0.isMultiple(of: 3)
                    ? ChatImageDimensions(width: 1, height: 10) : ChatImageDimensions(width: 10, height: 1) }
                let geometry = ChatImageGalleryGeometry(width: width, dimensions: dimensions)
                precondition(geometry.frames.count == min(4, count))
                precondition(geometry.frames.allSatisfy {
                    $0.width >= 43.99 && $0.height >= 44 && $0.height <= (count == 1 ? 300 : 240)
                        && $0.minX >= 0 && $0.maxX <= min(width, 640) + 0.01
                }, "Mixed-aspect rows must stay bounded with useful touch targets")
                if width >= 280, count == 3 { precondition(Set(geometry.frames.map(\.minY)).count == 1) }
                if width >= 280, count >= 4 { precondition(Set(geometry.frames.map(\.minY)).count == 2) }
                for first in geometry.frames.indices {
                    for second in geometry.frames.indices where first != second {
                        precondition(!geometry.frames[first].intersects(geometry.frames[second]), "Tiles cannot overlap")
                    }
                }
            }
        }
        let small = ChatImageGalleryGeometry(width: 640, dimensions: [.init(width: 80, height: 60)])
        precondition(small.size == CGSize(width: 80, height: 60), "Small single images should not expand to fill the transcript")
        precondition(ChatImageGalleryGeometry(width: 640, dimensions: []).size == .zero)
        let fallback = ChatImageGalleryGeometry(width: 320, dimensions: [nil, nil, nil])
        precondition(fallback.frames.count == 3 && fallback.frames.allSatisfy { $0.minY == 0 })

        let png = try image(width: 37, height: 83)
        let metadata = ChatImageMetadata()
        let original = await metadata.dimensions(data: png, file: nil)
        precondition(original == .init(width: 37, height: 83))
        let rotated = await metadata.dimensions(data: try image(width: 37, height: 83, orientation: 6), file: nil)
        precondition(rotated == .init(width: 83, height: 37), "EXIF rotation must also rotate the gallery's aspect")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.tiff")
        try png.write(to: file, options: .atomic)
        let before = await metadata.dimensions(data: nil, file: file)
        try image(width: 83, height: 37).write(to: file, options: .atomic)
        let after = await metadata.dimensions(data: nil, file: file)
        precondition(before == .init(width: 37, height: 83) && after == .init(width: 83, height: 37),
            "Replacing an image at the same path must invalidate cached dimensions")
        let invalid = await metadata.dimensions(data: Data([1, 2, 3]), file: nil)
        precondition(invalid == nil)
        print("Image layout: justified rows, width/height bounds, touch targets, native singles and metadata orientation/replacement passed")
    }

    static func image(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
