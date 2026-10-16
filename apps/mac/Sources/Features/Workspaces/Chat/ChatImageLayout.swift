// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import ImageIO
import CryptoKit

struct ChatImageDimensions: Equatable, Sendable {
    let width: CGFloat
    let height: CGFloat
    var aspect: CGFloat { min(2.2, max(0.65, width / height)) }
}

/// Geometry is computed from the parent's proposal, never from a measured
/// child frame. Loading metadata can refine it once without a layout loop.
struct ChatImageGalleryGeometry {
    let frames: [CGRect]
    let size: CGSize

    init(width: CGFloat, dimensions: [ChatImageDimensions?]) {
        let width = min(640, max(44, width.isFinite ? width : 640))
        let count = min(4, dimensions.count)
        let spacing: CGFloat = 6
        let capacity = max(1, min(3, Int((width + spacing) / (44 + spacing))))
        let ordinaryRowCount = count == 4 ? 2 : count
        let perRow = min(capacity, ordinaryRowCount)
        var frames: [CGRect] = []
        var top: CGFloat = 0
        var extent: CGFloat = 0
        var start = 0
        while start < count {
            let end = min(count, start + perRow)
            let aspects = (start..<end).map { dimensions[$0]?.aspect ?? 1.5 }
            let gaps = spacing * CGFloat(aspects.count - 1)
            let sum = aspects.reduce(0, +)
            var height = min(count == 1 ? 300 : 240, (width - gaps) / sum)
            if count == 1, let native = dimensions[0] {
                // Small originals need a useful target, not a gratuitous upscale.
                height = min(height, native.height, native.width / aspects[0])
            }
            height = max(44, height)
            let contentWidth = min(width - gaps, max(CGFloat(aspects.count) * 44, height * sum))
            var widths = aspects.map { contentWidth * $0 / sum }
            // Preserve touch targets even in a narrow, mixed-aspect row.
            var fixed: Set<Int> = []
            while let small = widths.indices.first(where: { !fixed.contains($0) && widths[$0] < 44 }) {
                fixed.insert(small)
                let remaining = contentWidth - CGFloat(fixed.count) * 44
                let flexibleAspect = aspects.indices.filter { !fixed.contains($0) }.reduce(CGFloat(0)) { $0 + aspects[$1] }
                for index in widths.indices {
                    widths[index] = fixed.contains(index) ? 44 : remaining * aspects[index] / flexibleAspect
                }
            }
            var left: CGFloat = 0
            for tileWidth in widths {
                frames.append(CGRect(x: left, y: top, width: tileWidth, height: height))
                left += tileWidth + spacing
            }
            extent = max(extent, left - spacing)
            top += height + spacing
            start = end
        }
        self.frames = frames
        size = CGSize(width: extent, height: max(0, top - spacing))
    }
}

/// Metadata only: ImageIO reads dimensions without decompressing full images.
/// The actor keeps at most 256 small entries and never retains image bytes.
actor ChatImageMetadata {
    static let shared = ChatImageMetadata()
    private enum Key: Hashable { case data(Data), file(ChatImageFileIdentity) }
    private struct Entry { let dimensions: ChatImageDimensions? }
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []

    func dimensions(data: Data?, file: URL?) -> ChatImageDimensions? {
        let key: Key
        if let data {
            // A hashValue is a bucket hint, not content identity. Some
            // Foundation versions sample bytes, so equal-size images whose
            // EXIF metadata differs can otherwise share cached dimensions.
            // Retain only the fixed-size digest, never the original pixels.
            key = .data(Data(SHA256.hash(data: data)))
        }
        else if let file, let identity = ChatImageFileIdentity(file) { key = .file(identity) }
        else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        if let cached = entries[key] { return cached.dimensions }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, options) }
            ?? file.flatMap { CGImageSourceCreateWithURL($0 as CFURL, options) }
        let dimensions = source.flatMap { source -> ChatImageDimensions? in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue.isFinite, height.doubleValue.isFinite,
                  width.doubleValue > 0, height.doubleValue > 0 else { return nil }
            let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
            return ChatImageDimensions(width: CGFloat(rotated ? height.doubleValue : width.doubleValue),
                height: CGFloat(rotated ? width.doubleValue : height.doubleValue))
        }
        entries[key] = Entry(dimensions: dimensions)
        if recency.count > 256 { entries.removeValue(forKey: recency.removeFirst()) }
        return dimensions
    }
}
