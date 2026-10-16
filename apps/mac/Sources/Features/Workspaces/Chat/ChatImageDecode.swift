// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import ImageIO
import CryptoKit
import Darwin

/// Attachment cache paths are reused after a purge/retry. Include the actual
/// file and nanosecond change time, including edits that restore the old mtime.
struct ChatImageFileIdentity: Hashable {
    let url: URL
    let device: UInt64
    let inode: UInt64
    let bytes: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init?(_ file: URL) {
        guard file.isFileURL else { return nil }
        let file = file.standardizedFileURL
        var attributes = stat()
        guard file.withUnsafeFileSystemRepresentation({ path in
            path.map { fstatat(AT_FDCWD, $0, &attributes, 0) == 0 } ?? false
        }), attributes.st_size >= 0, attributes.st_mode & S_IFMT == S_IFREG else { return nil }
        url = file
        device = UInt64(bitPattern: Int64(attributes.st_dev)); inode = UInt64(attributes.st_ino)
        bytes = UInt64(attributes.st_size)
        modifiedSeconds = Int64(attributes.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(attributes.st_mtimespec.tv_nsec)
        changedSeconds = Int64(attributes.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(attributes.st_ctimespec.tv_nsec)
    }
}

/// One off-main decode serves gallery cells and the viewer. The actor also
/// serializes overlapping requests, so a returning lazy row reuses pixels
/// instead of compressing a thumbnail to PNG and immediately decoding it again.
actor ChatImageDecodeCache {
    static let shared = ChatImageDecodeCache(observeMemoryPressure: true)

    #if os(macOS)
    static let defaultByteLimit = 64 * 1024 * 1024
    #else
    static let defaultByteLimit = 24 * 1024 * 1024
    #endif

    private enum Content: Hashable {
        // Fixed-size content identity; cache keys never retain original bytes.
        case data(Data)
        case file(ChatImageFileIdentity)
    }
    private struct Key: Hashable { let content: Content; let maxPixel: Int }
    private struct Entry { let image: CGImage; let cost: Int }
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []
    private let memoryPressure: DispatchSourceMemoryPressure?
    private(set) var cachedBytes = 0

    init(byteLimit: Int = defaultByteLimit, countLimit: Int = 96, observeMemoryPressure: Bool = false) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
        let pressure = observeMemoryPressure
            ? DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility)) : nil
        memoryPressure = pressure
        pressure?.setEventHandler { [weak self] in Task { await self?.removeAll() } }
        pressure?.resume()
    }

    deinit { memoryPressure?.cancel() }

    func image(data: Data?, file: URL?, maxPixel: CGFloat) -> CGImage? {
        guard !Task.isCancelled, maxPixel.isFinite, maxPixel > 0 else { return nil }
        let maxPixel = max(1, Int(ceil(min(3072, maxPixel))))
        let content: Content
        if let data { content = .data(Data(SHA256.hash(data: data))) }
        else if let file, let identity = ChatImageFileIdentity(file) { content = .file(identity) }
        else { return nil }
        let key = Key(content: content, maxPixel: maxPixel)
        if let cached = entries[key] {
            touch(key)
            return cached.image
        }
        guard !Task.isCancelled else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        if let data { source = CGImageSourceCreateWithData(data as CFData, sourceOptions) }
        else if let file { source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) }
        else { return nil }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        // A writer may atomically replace the path while ImageIO opens it.
        // Do not associate those pixels with the preceding file's identity.
        if case let .file(before) = content, ChatImageFileIdentity(before.url) != before { return nil }
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        if !overflow, cost > 0, cost <= byteLimit, countLimit > 0 {
            while cachedBytes > byteLimit - cost || entries.count >= countLimit {
                guard !recency.isEmpty else { break }
                if let evicted = entries.removeValue(forKey: recency.removeFirst()) { cachedBytes -= evicted.cost }
            }
            entries[key] = Entry(image: image, cost: cost)
            cachedBytes += cost
            touch(key)
        }
        return image
    }

    func removeAll() {
        entries.removeAll(); recency.removeAll(); cachedBytes = 0
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
