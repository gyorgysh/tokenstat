// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bytes ready to stage as a chat attachment: a name, a type, and the file.
struct ChatInboxItem: Sendable {
    var data: Data
    var name: String
    var mediaType: String?
}

/// What a drop means before the chat decides how to present it.
///
/// Keeping text and refusals beside attachments is deliberate: every surface
/// can share one decoding policy without pretending a sentence is a file or a
/// directory is an unreadable attachment.
enum ChatInboxDrop: Sendable {
    case attachment(ChatInboxItem)
    case text(String)
    case folder
}

/// Drops become explicit outcomes here, while pastes and the file picker share
/// the same attachment decoding path, so no composer talks to a pasteboard.
///
/// Screenshot thumbnails are the reason this is not just `Data(contentsOf:)`.
/// They often carry pixels without a durable file, or a `file://` that vanishes
/// when the thumbnail slides away. Read the bytes immediately. Convert TIFF and
/// HEIC to PNG so the agent CLI is opening something it can actually decode.
enum ChatInbox {
    static let maxBytes = 12 * 1024 * 1024
    static let dropTypes: [UTType] = [
        .fileURL, .url, .image, .png, .jpeg, .gif, .webP, .heic, .tiff, .pdf, .plainText,
    ]

    static func pasteboardHasAttachment() -> Bool {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            return true
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
        ]
        return pasteboard.availableType(from: imageTypes) != nil
            || NSImage(pasteboard: pasteboard) != nil
        #else
        let pasteboard = UIPasteboard.general
        return pasteboard.hasImages || (pasteboard.hasURLs && !(pasteboard.urls ?? []).isEmpty)
        #endif
    }

    static func pasteboardItems() -> [ChatInboxItem] {
        #if os(macOS)
        macPasteboardItems()
        #else
        iosPasteboardItems()
        #endif
    }

    static func items(from providers: [NSItemProvider]) async -> [ChatInboxItem] {
        var items: [ChatInboxItem] = []
        for provider in providers {
            if let item = await item(from: provider) {
                items.append(prepared(item))
            }
        }
        return items
    }

    static func drops(from providers: [NSItemProvider]) async -> [ChatInboxDrop] {
        var drops: [ChatInboxDrop] = []
        for provider in providers {
            if let drop = await drop(from: provider) {
                drops.append(drop)
            }
        }
        return drops
    }

    static func drops(from urls: [URL]) -> [ChatInboxDrop] {
        urls.compactMap(drop(from:))
    }

    static func imageDrop(from data: Data) -> ChatInboxDrop? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source)
        else { return nil }
        let type = UTType(identifier as String) ?? .png
        return .attachment(prepared(ChatInboxItem(
            data: data,
            name: defaultImageName(type),
            mediaType: type.preferredMIMEType ?? "image/png"
        )))
    }

    static func item(from url: URL) -> ChatInboxItem? {
        guard case let .attachment(item)? = drop(from: url) else { return nil }
        return item
    }

    static func drop(from url: URL) -> ChatInboxDrop? {
        guard url.isFileURL else {
            let text = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .text(text)
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return .folder }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return .attachment(prepared(
            ChatInboxItem(
                data: data,
                name: usableName(url.lastPathComponent),
                mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            )
        ))
    }

    static func prepared(_ item: ChatInboxItem) -> ChatInboxItem {
        let type = (item.mediaType ?? "").lowercased()
        let ext = (item.name as NSString).pathExtension.lowercased()
        let needsPNG = type.contains("heic")
            || type.contains("heif")
            || type.contains("tiff")
            || ext == "heic"
            || ext == "heif"
            || ext == "tif"
            || ext == "tiff"
        guard needsPNG, let png = pngData(from: item.data) else { return item }
        return ChatInboxItem(
            data: png,
            name: replacingExtension(item.name, with: "png"),
            mediaType: "image/png"
        )
    }

    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }

    // MARK: - Providers

    private static func item(from provider: NSItemProvider) async -> ChatInboxItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let item = await fileItem(from: provider)
        {
            return item
        }
        let imageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .tiff, .image]
        for type in imageTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(from: provider, type: type), !data.isEmpty {
                return ChatInboxItem(
                    data: data,
                    name: defaultImageName(type),
                    mediaType: type.preferredMIMEType ?? "image/png"
                )
            }
        }
        return nil
    }

    private static func drop(from provider: NSItemProvider) async -> ChatInboxDrop? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = await url(from: provider, type: .fileURL) else { return nil }
            return drop(from: url)
        }
        let imageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .tiff, .image]
        for type in imageTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(from: provider, type: type), !data.isEmpty {
                return .attachment(prepared(ChatInboxItem(
                    data: data,
                    name: defaultImageName(type),
                    mediaType: type.preferredMIMEType ?? "image/png"
                )))
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await url(from: provider, type: .url)
        {
            return drop(from: url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await text(from: provider)
        {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : .text(clean)
        }
        return nil
    }

    private static func fileItem(from provider: NSItemProvider) async -> ChatInboxItem? {
        guard let url = await url(from: provider) else { return nil }
        return item(from: url)
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await url(from: provider, type: .fileURL)
    }

    private static func url(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let text = item as? String {
                    continuation.resume(returning: URL(string: text))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let text = item as? NSAttributedString {
                    continuation.resume(returning: text.string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Pasteboards

    #if os(macOS)
    private static func macPasteboardItems() -> [ChatInboxItem] {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let items = urls.compactMap(item(from:))
            if !items.isEmpty { return items }
        }
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return [prepared(ChatInboxItem(data: png, name: "image.png", mediaType: "image/png"))]
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")), !jpeg.isEmpty {
            return [prepared(ChatInboxItem(data: jpeg, name: "image.jpg", mediaType: "image/jpeg"))]
        }
        if let tiff = pasteboard.data(forType: .tiff), let png = pngData(from: tiff) {
            return [ChatInboxItem(data: png, name: "image.png", mediaType: "image/png")]
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let png = pngData(from: tiff)
        {
            return [ChatInboxItem(data: png, name: "image.png", mediaType: "image/png")]
        }
        return []
    }
    #else
    private static func iosPasteboardItems() -> [ChatInboxItem] {
        let pasteboard = UIPasteboard.general
        if let images = pasteboard.images, !images.isEmpty {
            return images.enumerated().compactMap { index, image in
                guard let data = image.pngData(), !data.isEmpty else { return nil }
                let name = index == 0 ? "image.png" : "image-\(index + 1).png"
                return ChatInboxItem(data: data, name: name, mediaType: "image/png")
            }
        }
        if let urls = pasteboard.urls {
            return urls.compactMap(item(from:))
        }
        return []
    }
    #endif

    private static func defaultImageName(_ type: UTType) -> String {
        switch type {
        case .jpeg: return "image.jpg"
        case .gif: return "image.gif"
        case .webP: return "image.webp"
        default: return "image.png"
        }
    }

    private static func usableName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" { return "file" }
        return trimmed
    }

    private static func replacingExtension(_ name: String, with ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let stem = base.isEmpty ? "image" : base
        return "\(stem).\(ext)"
    }
}

enum ChatThumbnail {
    static func make(from data: Data, maxPixel: CGFloat = 192) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
