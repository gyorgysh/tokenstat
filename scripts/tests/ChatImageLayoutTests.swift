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
        for orientation in 1...8 {
            let encoded = try image(width: 37, height: 83, orientation: orientation)
            let source = CGImageSourceCreateWithData(encoded as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            precondition((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == orientation,
                         "The fixture must contain the requested EXIF orientation")
            let rotated = await metadata.dimensions(data: encoded, file: nil)
            let expected = (5...8).contains(orientation)
                ? ChatImageDimensions(width: 83, height: 37) : ChatImageDimensions(width: 37, height: 83)
            precondition(rotated == expected,
                         "EXIF orientation \(orientation): expected \(expected), got \(String(describing: rotated))")
        }
        // These fixtures have identical lengths and differ only in an EXIF
        // field beyond the prefix sampled by older Foundation data hashes.
        // Revisit both cached variants: hash/count alone cannot identify them.
        let portrait = try image(width: 37, height: 83, orientation: 1)
        let landscape = try image(width: 37, height: 83, orientation: 6)
        precondition(portrait.count == landscape.count && portrait != landscape)
        for rotated in [false, true, false, true] {
            let cached = await metadata.dimensions(data: rotated ? landscape : portrait, file: nil)
            precondition(cached == (rotated ? .init(width: 83, height: 37) : .init(width: 37, height: 83)),
                         "Same-size EXIF variants must retain independent metadata cache entries")
        }
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

    // A minimal, uncompressed RGB TIFF keeps the fixture independent of
    // ImageIO encoder versions, which can normalize orientation on write.
    static func image(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        var bytes = Data()
        func u16(_ value: Int) { bytes.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255)]) }
        func u32(_ value: Int) { u16(value & 65535); u16((value >> 16) & 65535) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) {
            u16(tag); u16(type); u32(count); u32(value)
        }
        let count = 11, bitsOffset = 8 + 2 + 11 * 12 + 4, pixelOffset = bitsOffset + 6
        bytes.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
        u16(count)
        entry(256, 4, 1, width)
        entry(257, 4, 1, height)
        entry(258, 3, 3, bitsOffset)
        entry(259, 3, 1, 1)
        entry(262, 3, 1, 2)
        entry(273, 4, 1, pixelOffset)
        entry(274, 3, 1, orientation)
        entry(277, 3, 1, 3)
        entry(278, 4, 1, height)
        entry(279, 4, 1, width * height * 3)
        entry(284, 3, 1, 1)
        u32(0)
        u16(8); u16(8); u16(8)
        bytes.append(Data(repeating: 0, count: width * height * 3))
        return bytes
    }
}
