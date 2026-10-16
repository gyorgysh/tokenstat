// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run with scripts/benchmark-apple-chat-images.sh and caller-owned local fixtures.
import Foundation
import ImageIO

private func milliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
private func stats(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["loads": Double(values.count), "totalMs": values.reduce(0, +),
            "medianMs": sorted[sorted.count / 2], "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)]]
}

/// Include the encoded preview's first render decode, so both paths finish
/// with ready-to-draw pixels. These timings measure native components, not FPS.
private func encodedPreview(_ data: Data, maxPixel: CGFloat) -> Int? {
    autoreleasepool {
        guard let encoded = ChatThumbnail.make(from: data, maxPixel: maxPixel, preservingAlpha: true),
              let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return image.width
    }
}

@main enum AppleChatImages {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let limit = Int(CommandLine.arguments[2]), (1...256).contains(limit) else {
            throw NSError(domain: "AppleChatImages", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The sample limit must be between 1 and 256."])
        }
        let extensions = Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"])
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])?.compactMap { item -> URL? in
                guard let file = item as? URL, extensions.contains(file.pathExtension.lowercased()),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                return file
            }.sorted { $0.path < $1.path } ?? []
        let samples = try files.prefix(limit).map { try Data(contentsOf: $0) }
        guard !samples.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        var report: [[String: Any]] = []
        var checksum = 0
        for edge: CGFloat in [192, 1280, 3072] {
            let uncached = ChatImageDecodeCache(byteLimit: 0)
            let cache = ChatImageDecodeCache()
            var before: [Double] = [], cold: [Double] = [], sweeps: [Double] = [], warm: [Double] = []
            var maxCached = 0
            for data in samples {
                let start = milliseconds()
                guard let width = encodedPreview(data, maxPixel: edge) else { throw CocoaError(.fileReadCorruptFile) }
                before.append(milliseconds() - start); checksum &+= width
                let next = milliseconds()
                guard let image = await uncached.image(data: data, file: nil, maxPixel: edge) else { throw CocoaError(.fileReadCorruptFile) }
                cold.append(milliseconds() - next); checksum &+= image.width
            }
            for _ in 0..<3 {
                for data in samples {
                    let start = milliseconds()
                    guard let image = await cache.image(data: data, file: nil, maxPixel: edge) else { throw CocoaError(.fileReadCorruptFile) }
                    sweeps.append(milliseconds() - start); checksum &+= image.width
                    maxCached = max(maxCached, await cache.cachedBytes)
                }
            }
            let revisit = ChatImageDecodeCache()
            for data in samples.prefix(6) { _ = await revisit.image(data: data, file: nil, maxPixel: edge) }
            for _ in 0..<4 {
                for data in samples.prefix(6) {
                    let start = milliseconds()
                    guard let image = await revisit.image(data: data, file: nil, maxPixel: edge) else { throw CocoaError(.fileReadCorruptFile) }
                    warm.append(milliseconds() - start); checksum &+= image.width
                }
            }
            precondition(maxCached <= ChatImageDecodeCache.defaultByteLimit)
            report.append(["maxPixel": edge, "encodedPreview": stats(before), "directCold": stats(cold),
                "threeScrollSweeps": stats(sweeps), "revisitSix": stats(warm),
                "peakCachedBytes": maxCached, "cacheLimitBytes": ChatImageDecodeCache.defaultByteLimit])
        }
        let result: [String: Any] = ["images": samples.count, "inputBytes": samples.reduce(0) { $0 + $1.count },
            "optimized": true, "timingScope": "native image components; not frame rate", "results": report, "checksum": checksum]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
