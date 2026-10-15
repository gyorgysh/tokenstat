// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run with ChatInbox.swift WorkReference.swift using swiftc -parse-as-library, then run the binary.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct ChatAttachmentCacheTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func reference(_ host: String = "phone-host", chat: String = "chat", account: String = "one", folder: String = "folder") -> WorkReference {
            .init(scope: .local(installationID: account), hostIdentity: host, workspaceID: folder, kind: .conversation, itemID: chat)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let importFile = root.appendingPathComponent("large.heic")
        try Data([0x61, 0x62, 0x63]).write(to: importFile)
        require(ChatInbox.boundedFileData(from: importFile) == Data([0x61, 0x62, 0x63]), "Small file preserved")
        let large = try FileHandle(forWritingTo: importFile)
        try large.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try large.close()
        guard case let .attachment(imported)? = ChatInbox.drop(from: importFile) else {
            fatalError("Oversized import must reach the size-limit explanation")
        }
        require(imported.data.isEmpty && imported.importFailure != nil, "Oversized import carries a refusal without reading bytes")
        require(imported.name == "large.heic", "Oversized image is not converted")
        require(try importFile.resourceValues(forKeys: [.fileSizeKey]).fileSize == 4 * 1024 * 1024 * 1024, "Original file is unchanged")
        require(ChatInbox.boundedFileData(from: root) == nil, "Directory is not a file")
        try FileManager.default.removeItem(at: importFile)
        let cache = ChatAttachmentCache(directory: root, budget: 1024)
        let bytes = Data("file contents".utf8)
        await cache.write(bytes, reference: reference(), attachment: "file")
        require(await cache.read(reference: reference(), attachment: "file") == bytes, "Byte round trip")
        require(await cache.read(reference: reference("other-host"), attachment: "file") == nil, "Peer isolation")
        require(await cache.read(reference: reference(chat: "other-chat"), attachment: "file") == nil, "Chat isolation")
        require(await cache.read(reference: reference(account: "other"), attachment: "file") == nil, "Account isolation")
        require(await cache.read(reference: reference(folder: "other"), attachment: "file") == nil, "Folder isolation")
        let reopened = ChatAttachmentCache(directory: root)
        require(await reopened.read(reference: reference(), attachment: "file") == bytes, "Persistent reuse")
        let resumed = root.appendingPathComponent("resumed.mov")
        try bytes.write(to: resumed)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 30)], ofItemAtPath: resumed.path)
        let completed = try await reopened.writeFile(resumed, reference: reference(), attachment: "video", epoch: await reopened.epoch())
        require(try Data(contentsOf: completed) == bytes, "Completed resumed download starts a fresh retention period")
        let cachedVideo = await reopened.readFile(reference: reference(), attachment: "video", size: UInt64(bytes.count))
        require(cachedVideo?.standardizedFileURL == completed.standardizedFileURL, "Resumed download remains reusable")
        let expired = ChatAttachmentCache(directory: root, lifetime: 0)
        require(await expired.read(reference: reference(), attachment: "file") == nil, "Expired cache miss")

        let smallRoot = root.appendingPathComponent("bounded")
        let bounded = ChatAttachmentCache(directory: smallRoot, budget: 8)
        await bounded.write(Data([1, 1, 1, 1]), reference: reference(), attachment: "old")
        let firstFile = try FileManager.default.contentsOfDirectory(at: smallRoot, includingPropertiesForKeys: nil)[0]
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: firstFile.path)
        await bounded.write(Data([2, 2, 2, 2]), reference: reference(), attachment: "second")
        await bounded.write(Data([3, 3, 3, 3]), reference: reference(), attachment: "third")
        require(await bounded.read(reference: reference(), attachment: "old") == nil, "Oldest evicted")
        require(await bounded.read(reference: reference(), attachment: "third") == Data([3, 3, 3, 3]), "Newest retained")
        let sizes = try FileManager.default.contentsOfDirectory(at: smallRoot, includingPropertiesForKeys: [.fileSizeKey])
            .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        require(sizes.reduce(0, +) <= 8, "Disk budget")

        // File-backed originals use the same bounded inline preview as small
        // images. The decoder must not allocate the original pixel dimensions.
        let imageFile = root.appendingPathComponent("original.png")
        let context = CGContext(data: nil, width: 4096, height: 2048, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(imageFile as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        require(CGImageDestinationFinalize(destination), "Image fixture written")
        let thumb = ChatThumbnail.make(from: imageFile, maxPixel: 1440, preservingAlpha: true)!
        let source = CGImageSourceCreateWithData(thumb as CFData, nil)!
        let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        require(pixels.width == 1440 && pixels.height == 720, "Large file preview is downsampled and keeps its aspect")
        require([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(pixels.alphaInfo), "File preview preserves transparency")
        let inline = ChatThumbnail.make(from: try Data(contentsOf: imageFile), maxPixel: 1440, preservingAlpha: true)!
        let inlineSource = CGImageSourceCreateWithData(inline as CFData, nil)!
        let inlinePixels = CGImageSourceCreateImageAtIndex(inlineSource, 0, nil)!
        require([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(inlinePixels.alphaInfo), "Inline preview preserves transparency")
        require(ChatThumbnail.make(from: root.appendingPathComponent("missing.png")) == nil, "Missing image fails gracefully")

        // Floating screenshot drags can advertise a vanished file URL as
        // well as valid pixels. Exercise the real provider decoding path.
        let imageBytes = try Data(contentsOf: imageFile)
        func provider(_ url: URL, pixels: Data? = nil, failsURL: Bool = false) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                if failsURL { completion(nil, CocoaError(.fileReadNoSuchFile)) }
                else { completion(url.dataRepresentation, nil) }
                return nil
            }
            if let pixels {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                    completion(pixels, nil)
                    return nil
                }
            }
            return provider
        }
        let missing = root.appendingPathComponent("vanished-screenshot.png")
        for failsURL in [false, true] {
            let drops = await ChatInbox.drops(from: [provider(missing, pixels: imageBytes, failsURL: failsURL)])
            guard drops.count == 1, case let .attachment(item) = drops[0] else {
                fatalError("An unavailable screenshot URL must fall back to its image pixels")
            }
            require(item.data == imageBytes && item.mediaType == "image/png", "Fallback preserves the screenshot pixels")
        }
        let durable = root.appendingPathComponent("notes.txt")
        let originalBytes = Data("Keep the selected file".utf8)
        try originalBytes.write(to: durable)
        let fileDrops = await ChatInbox.drops(from: [provider(durable, pixels: imageBytes)])
        guard fileDrops.count == 1, case let .attachment(fileItem) = fileDrops[0] else {
            fatalError("A readable file remains the preferred representation")
        }
        require(fileItem.name == "notes.txt" && fileItem.data == originalBytes, "Finder file retains its name and bytes")
        let missingDrops = await ChatInbox.drops(from: [provider(missing)])
        require(missingDrops.isEmpty, "A missing file without pixels is not inserted as a URL")
        let failedFile = provider(missing, failsURL: true)
        failedFile.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(missing.absoluteString.utf8), nil)
            return nil
        }
        let failedDrops = await ChatInbox.drops(from: [failedFile])
        require(failedDrops.isEmpty, "A failed file representation must not become a pasted file URL")
        let pdfBytes = Data("%PDF-1.4\n%%EOF\n".utf8)
        let pdf = NSItemProvider()
        pdf.suggestedName = "report.pdf"
        pdf.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            completion(pdfBytes, nil)
            return nil
        }
        let pdfDrops = await ChatInbox.drops(from: [pdf])
        guard pdfDrops.count == 1, case let .attachment(pdfItem) = pdfDrops[0] else {
            fatalError("A PDF data drag must produce a file attachment")
        }
        require(pdfItem.name == "report.pdf" && pdfItem.mediaType == "application/pdf" && pdfItem.data == pdfBytes,
            "PDF drag preserves its name, type and bytes")
        let folderDrops = await ChatInbox.drops(from: [provider(root, pixels: imageBytes)])
        guard folderDrops.count == 1, case .folder = folderDrops[0] else {
            fatalError("A folder still reaches the existing folder explanation")
        }

        require(ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 5_242_880), "5 MiB automatic")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 5_242_881), "Above 5 MiB manual")
        require(ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 200_000_000, isLocalImage: true), "Local images bypass network threshold")
        require(ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: nil, isLocalImage: true), "Local images with unknown size can load")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 0, isLocalImage: true), "Empty local image is not fetched")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: nil), "Unknown size manual")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 0), "Empty size manual")
        let purgeRoot = root.appendingPathComponent("purge")
        let previews = root.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try bytes.write(to: previews.appendingPathComponent("preview.txt"))
        let purgeCache = ChatAttachmentCache(directory: purgeRoot, previewDirectory: previews)
        let epoch = await purgeCache.epoch()
        await purgeCache.write(bytes, reference: reference(), attachment: "file", epoch: epoch)
        require(await purgeCache.usedBytes() == bytes.count * 2, "Previews counted")
        try await purgeCache.purge()
        require(await purgeCache.usedBytes() == 0, "Purge downloads and previews")
        require(!(await purgeCache.write(bytes, reference: reference(), attachment: "late", epoch: epoch)), "Late download cannot restore purge")
        require(await purgeCache.read(reference: reference(), attachment: "late") == nil, "Purged bytes stay absent")
        require(ChatCachePreferences.sizes.contains(5) && ChatCachePreferences.days.last == 30, "Supported settings")
        print("Attachment imports, screenshot fallback, cache and download policy checks passed")
    }
}
