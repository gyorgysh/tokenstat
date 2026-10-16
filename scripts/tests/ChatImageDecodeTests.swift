// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatImageDecode.swift and ImageIO.
import Foundation
import ImageIO
import Darwin

@main struct ChatImageDecodeTests {
    static func main() async throws {
        let portrait = tiff(width: 37, height: 83, orientation: 1)
        let landscape = tiff(width: 37, height: 83, orientation: 6)
        precondition(portrait.count == landscape.count && portrait != landscape)
        let cache = ChatImageDecodeCache()
        let first = await cache.image(data: portrait, file: nil, maxPixel: 1280)!
        let equalCopy = await cache.image(data: Data(Array(portrait)), file: nil, maxPixel: 1280)!
        precondition(first === equalCopy, "Identical bytes reuse decoded pixels even after the lazy row is recreated")
        let rotated = await cache.image(data: landscape, file: nil, maxPixel: 1280)!
        precondition(first.width == 37 && first.height == 83 && rotated.width == 83 && rotated.height == 37)
        precondition(first !== rotated, "Equal-length sources with changed EXIF must not share a cache entry")
        for orientation in 1...8 {
            let image = await cache.image(data: tiff(width: 37, height: 83, orientation: orientation), file: nil, maxPixel: 40)!
            precondition(max(image.width, image.height) <= 40)
            precondition((image.width > image.height) == (5...8).contains(orientation), "EXIF rotation must survive direct decoding")
        }
        let thumbnails = await withTaskGroup(of: CGImage?.self, returning: [CGImage].self) { group in
            for _ in 0..<24 { group.addTask { await cache.image(data: portrait, file: nil, maxPixel: 1280) } }
            var values: [CGImage] = []
            for await image in group { values.append(image!) }
            return values
        }
        precondition(thumbnails.allSatisfy { $0 === first }, "Overlapping cells must share one decoded image")

        let transparent = try alphaPNG()
        let alpha = await cache.image(data: transparent, file: nil, maxPixel: 1280)!
        let pixels = rgba(alpha)
        precondition(pixels[3] == 0 && (127...129).contains(pixels[7]) && pixels[11] == 255,
                     "Direct thumbnails must preserve transparent and partially transparent pixels")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("same-path.tiff")
        precondition(ChatImageFileIdentity(directory) == nil)
        let fifo = directory.appendingPathComponent("not-an-image.fifo")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        precondition(ChatImageFileIdentity(fifo) == nil, "A FIFO must be rejected before ImageIO could wait on its writer")
        try portrait.write(to: file, options: .atomic)
        let originalDate = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        let oldFile = await cache.image(data: nil, file: file, maxPixel: 1280)!
        let sameFile = await cache.image(data: nil, file: file, maxPixel: 1280)!
        precondition(oldFile === sameFile)
        try landscape.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        let replaced = await cache.image(data: nil, file: file, maxPixel: 1280)!
        precondition(replaced.width == 83 && replaced.height == 37 && replaced !== oldFile,
                     "Atomic replacement must invalidate even when path, byte count and modification date match")
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: portrait)
        try writer.close()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        let edited = await cache.image(data: nil, file: file, maxPixel: 1280)!
        precondition(edited.width == 37 && edited.height == 83 && edited !== replaced,
                     "An in-place, equal-length edit restoring mtime must invalidate using nanosecond ctime")
        try? FileManager.default.removeItem(at: file)
        let removed = await cache.image(data: nil, file: file, maxPixel: 1280)
        precondition(removed == nil, "A removed file cannot be resurrected from its old cache entry")

        let cost = first.bytesPerRow * first.height
        let bounded = ChatImageDecodeCache(byteLimit: cost, countLimit: 2)
        let kept = await bounded.image(data: portrait, file: nil, maxPixel: 1280)!
        _ = await bounded.image(data: landscape, file: nil, maxPixel: 1280)
        let bytes = await bounded.cachedBytes
        precondition(bytes <= cost)
        let reloaded = await bounded.image(data: portrait, file: nil, maxPixel: 1280)!
        precondition(kept !== reloaded, "Decoded bytes, rather than encoded size, must drive eviction")
        let counted = ChatImageDecodeCache(byteLimit: 1024 * 1024, countLimit: 1)
        let countedFirst = await counted.image(data: portrait, file: nil, maxPixel: 1280)!
        _ = await counted.image(data: landscape, file: nil, maxPixel: 1280)
        let countedAgain = await counted.image(data: portrait, file: nil, maxPixel: 1280)!
        precondition(countedFirst !== countedAgain, "Small images must also obey the entry limit")
        let oversized = ChatImageDecodeCache(byteLimit: 1)
        let uncached = await oversized.image(data: portrait, file: nil, maxPixel: 1280)
        precondition(uncached != nil)
        let uncachedBytes = await oversized.cachedBytes
        precondition(uncachedBytes == 0, "A large viewer image can display without exceeding cache budget")
        let cancelledCache = ChatImageDecodeCache()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancelledCache.image(data: portrait, file: nil, maxPixel: 1280)
        }
        let cancelledResult = await cancelled.value
        let cancelledBytes = await cancelledCache.cachedBytes
        precondition(cancelledResult == nil && cancelledBytes == 0, "A canceled offscreen row must skip decoding")
        for size in [CGFloat.nan, .infinity, 0, -1] {
            let invalid = await cache.image(data: portrait, file: nil, maxPixel: size)
            precondition(invalid == nil)
        }
        let huge = await cache.image(data: portrait, file: nil, maxPixel: .greatestFiniteMagnitude)
        precondition(huge != nil, "An extreme request must clamp without overflowing integer conversion")
        let invalidData = await cache.image(data: Data([1, 2, 3]), file: nil, maxPixel: 1280)
        precondition(invalidData == nil)
        await cache.removeAll()
        let emptyBytes = await cache.cachedBytes
        precondition(emptyBytes == 0)
        print("Image decoding: shared bounded pixels, content identity, file replacement, orientation, alpha, cancellation and eviction passed")
    }

    static func alphaPNG() throws -> Data {
        let bytes: [UInt8] = [0, 0, 0, 0, 64, 0, 0, 128, 0, 255, 0, 255]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    // The orientation field survives unchanged instead of an encoder
    // normalizing it; the two orientations have exactly equal byte counts.
    static func tiff(width: Int, height: Int, orientation: Int) -> Data {
        var data = Data()
        func u16(_ value: Int) { data.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255)]) }
        func u32(_ value: Int) { u16(value & 65535); u16((value >> 16) & 65535) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }
        let bits = 8 + 2 + 11 * 12 + 4, pixels = bits + 6
        data.append(contentsOf: [0x49, 0x49]); u16(42); u32(8); u16(11)
        entry(256, 4, 1, width); entry(257, 4, 1, height); entry(258, 3, 3, bits)
        entry(259, 3, 1, 1); entry(262, 3, 1, 2); entry(273, 4, 1, pixels)
        entry(274, 3, 1, orientation); entry(277, 3, 1, 3); entry(278, 4, 1, height)
        entry(279, 4, 1, width * height * 3); entry(284, 3, 1, 1); u32(0)
        u16(8); u16(8); u16(8); data.append(Data(repeating: 64, count: width * height * 3))
        return data
    }
}
