// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run with ChatInbox.swift using swiftc -parse-as-library, then run the binary.
import Foundation

@main
struct ChatAttachmentCacheTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ChatAttachmentCache(directory: root, budget: 1024)
        let bytes = Data("file contents".utf8)
        await cache.write(bytes, peer: "phone-host", chat: "chat", attachment: "file")
        require(await cache.read(peer: "phone-host", chat: "chat", attachment: "file") == bytes, "Byte round trip")
        require(await cache.read(peer: "other-host", chat: "chat", attachment: "file") == nil, "Peer isolation")
        require(await cache.read(peer: "phone-host", chat: "other-chat", attachment: "file") == nil, "Chat isolation")
        let reopened = ChatAttachmentCache(directory: root)
        require(await reopened.read(peer: "phone-host", chat: "chat", attachment: "file") == bytes, "Persistent reuse")
        let expired = ChatAttachmentCache(directory: root, lifetime: 0)
        require(await expired.read(peer: "phone-host", chat: "chat", attachment: "file") == nil, "Expired cache miss")

        let smallRoot = root.appendingPathComponent("bounded")
        let bounded = ChatAttachmentCache(directory: smallRoot, budget: 8)
        await bounded.write(Data([1, 1, 1, 1]), peer: nil, chat: "chat", attachment: "old")
        let firstFile = try FileManager.default.contentsOfDirectory(at: smallRoot, includingPropertiesForKeys: nil)[0]
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: firstFile.path)
        await bounded.write(Data([2, 2, 2, 2]), peer: nil, chat: "chat", attachment: "second")
        await bounded.write(Data([3, 3, 3, 3]), peer: nil, chat: "chat", attachment: "third")
        require(await bounded.read(peer: nil, chat: "chat", attachment: "old") == nil, "Oldest evicted")
        require(await bounded.read(peer: nil, chat: "chat", attachment: "third") == Data([3, 3, 3, 3]), "Newest retained")
        let sizes = try FileManager.default.contentsOfDirectory(at: smallRoot, includingPropertiesForKeys: [.fileSizeKey])
            .map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        require(sizes.reduce(0, +) <= 8, "Disk budget")

        require(ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 1_048_576), "1 MiB automatic")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 1_048_577), "Above 1 MiB manual")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: nil), "Unknown size manual")
        require(!ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: 0), "Empty size manual")
        let purgeRoot = root.appendingPathComponent("purge")
        let previews = root.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try bytes.write(to: previews.appendingPathComponent("preview.txt"))
        let purgeCache = ChatAttachmentCache(directory: purgeRoot, previewDirectory: previews)
        let epoch = await purgeCache.epoch()
        await purgeCache.write(bytes, peer: nil, chat: "chat", attachment: "file", epoch: epoch)
        require(await purgeCache.usedBytes() == bytes.count * 2, "Previews counted")
        try await purgeCache.purge()
        require(await purgeCache.usedBytes() == 0, "Purge downloads and previews")
        require(!(await purgeCache.write(bytes, peer: nil, chat: "chat", attachment: "late", epoch: epoch)), "Late download cannot restore purge")
        require(await purgeCache.read(peer: nil, chat: "chat", attachment: "late") == nil, "Purged bytes stay absent")
        require(ChatCachePreferences.sizes.contains(5) && ChatCachePreferences.days.last == 30, "Supported settings")
        print("Attachment cache and download policy checks passed")
    }
}
