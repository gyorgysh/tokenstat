// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatLocalAttachmentStore.swift ChatFileIO.swift ChatFileStaging.swift ChatDraftStore.swift. OriginalFileCoordination.swift.
import Foundation
struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String; var name: String; var mediaType: String?; var size: UInt64?
}
actor UploadCounter {
    var count = 0
    func upload(_ bytes: Data) async throws -> ChatAttachment {
        count += 1
        try await Task.sleep(for: .milliseconds(20))
        return .init(id: "host-file", name: "draft.txt", mediaType: "text/plain", size: UInt64(bytes.count))
    }
}
private final class CopyResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func succeeded() { lock.withLock { count += 1 } }
}
@main struct ChatLocalAttachmentStoreTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        @Sendable func ref(_ account: String = "one", host: String = "host", folder: String = "folder") -> WorkReference {
            .init(scope: .local(installationID: account), hostIdentity: host, workspaceID: folder, kind: .conversation, itemID: "conversation")
        }
        let store = ChatLocalAttachmentStore(directory: root)
        let bytes = Data("Unsent source file".utf8)
        let attachment = try await store.stage(data: bytes, name: "draft.txt", mediaType: "text/plain", reference: ref())
        assert(ChatLocalAttachmentStore.isLocal(attachment))
        let reopened = ChatLocalAttachmentStore(directory: root)
        let restored = try await reopened.read(attachment, reference: ref())
        assert(restored == bytes)
        for other in [ref("two"), ref(host: "other"), ref(folder: "other")] {
            do { _ = try await reopened.read(attachment, reference: other); assertionFailure("Wrong owner read original") } catch {}
        }
        let largeURL = root.appendingPathComponent("video.mov")
        FileManager.default.createFile(atPath: largeURL.path, contents: Data())
        let largeHandle = try FileHandle(forWritingTo: largeURL)
        try largeHandle.truncate(atOffset: 20 * 1024 * 1024); try largeHandle.close()
        let sharedCopy = root.appendingPathComponent("shared-copy.mov")
        let attempts = CopyResults()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { try ChatFileIO.copy(largeURL, to: sharedCopy); attempts.succeeded() } catch {}
        }
        assert(attempts.count == 1, "Only one concurrent original copy may create the destination")
        let copiedHash = try ChatFileIO.hash(sharedCopy)
        let sourceHash = try ChatFileIO.hash(largeURL)
        assert(copiedHash == sourceHash, "Refused concurrent copies preserve the winning original")
        try FileManager.default.removeItem(at: sharedCopy)
        let video = try await store.stage(file: largeURL, name: "video.mov", mediaType: "video/quicktime", reference: ref())
        let videoPresent = await reopened.contains(video, reference: ref())
        assert(videoPresent)
        do { _ = try await reopened.read(video, reference: ref()); assertionFailure("Large originals must not become whole-file Data") } catch {}
        let streamed = try await reopened.resolveStream(video, reference: ref()) { url in
            let (size, _) = try ChatFileIO.hash(url)
            return ChatAttachment(id: "uploaded-video", name: "video.mov", mediaType: "video/quicktime", size: size)
        }
        assert(streamed.size == 20 * 1024 * 1024)
        let exported = try await reopened.exportURL(video, reference: ref())
        let exportedSize = try exported.resourceValues(forKeys: [.fileSizeKey]).fileSize
        assert(exportedSize == 20 * 1024 * 1024)
        let exportedDigest = try ChatFileIO.hash(exported).1
        let originalDigest = try ChatFileIO.hash(largeURL).1
        assert(exportedDigest == originalDigest)
        try FileManager.default.removeItem(at: exported)
        let retainedVideo = ChatAttachment(id: "retained-video", name: "video.mov", mediaType: "video/quicktime", size: video.size)
        try await reopened.keep(retainedVideo, file: largeURL, reference: ref())
        do {
            try await reopened.keep(retainedVideo, file: largeURL, reference: ref())
            assertionFailure("Duplicate sidecar must not overwrite the original")
        } catch {}
        let stillRetained = await reopened.contains(retainedVideo, reference: ref())
        assert(stillRetained, "Failed duplicate import must preserve existing original bytes")
        let retainedExport = try await reopened.exportURL(retainedVideo, reference: ref())
        let retainedDigest = try ChatFileIO.hash(retainedExport).1
        assert(retainedDigest == originalDigest)
        try FileManager.default.removeItem(at: retainedExport)
        let retainedVideoEntry = try await reopened.retained(in: ref().scope).files.first { $0.attachment.id == retainedVideo.id }!
        try await reopened.remove(retainedVideoEntry, ifUnused: { true })
        let videoListing = try await reopened.retained(in: ref().scope)
        let videoEntry = videoListing.files.first { $0.attachment.id == video.id }!
        assert(videoEntry.bytes > 20 * 1024 * 1024)
        try await reopened.remove(videoEntry, ifUnused: { true })
        let removedVideo = await reopened.contains(video, reference: ref())
        assert(!removedVideo)
        let counter = UploadCounter()
        async let first = reopened.resolve(attachment, reference: ref()) { try await counter.upload($0) }
        async let second = reopened.resolve(attachment, reference: ref()) { try await counter.upload($0) }
        let resolved = try await (first, second)
        assert(resolved.0.id == "host-file" && resolved.1 == resolved.0)
        let count = await counter.count
        assert(count == 1, "Concurrent consumers share one upload")
        let relaunched = ChatLocalAttachmentStore(directory: root)
        let reused = try await relaunched.resolve(attachment, reference: ref()) { _ in
            assertionFailure("Persisted upload must not upload again")
            throw CancellationError()
        }
        assert(reused == resolved.0)
        let original = try await relaunched.read(attachment, reference: ref())
        assert(original == bytes, "Sending never discards the original file as cache")
        let retained = try await relaunched.retained(in: ref().scope)
        assert(retained.files.count == 1 && !retained.hasUnreadableFiles)
        let otherOwner = try await relaunched.retained(in: ref("two").scope)
        assert(otherOwner.files.isEmpty)
        let entry = retained.files[0]
        // A removal selected before the first upload cannot erase its newer mapping.
        let unuploaded = try await relaunched.stage(data: bytes, name: "other.txt", mediaType: "text/plain", reference: ref())
        let beforeUpload = try await relaunched.retained(in: ref().scope).files.first { $0.attachment.id == unuploaded.id }!
        _ = try await relaunched.resolve(unuploaded, reference: ref()) { try await counter.upload($0) }
        do { try await relaunched.remove(beforeUpload, ifUnused: { true }); assertionFailure("Stale removal deleted changed file") } catch {}
        let current = try await relaunched.retained(in: ref().scope).files.first { $0.attachment.id == unuploaded.id }!
        // Reproduce the old sheet race: its initial reference snapshot is
        // empty, then another window saves a draft before actor deletion runs.
        let drafts = ChatDraftStore(directory: root.appendingPathComponent("draft-state"))
        let initiallyUsed = try drafts.referencedAttachmentIDs(for: ref()).contains(unuploaded.id)
        assert(!initiallyUsed)
        let removal = Task {
            try await relaunched.remove(current) {
                try !drafts.referencedAttachmentIDs(for: ref()).contains(unuploaded.id)
            }
        }
        drafts.save(text: "Keep this file", attachments: [unuploaded], for: ref())
        do {
            try await removal.value
            assertionFailure("Removed an original newly referenced by another window")
        } catch ChatLocalAttachmentStore.Failure.inUse {}
        let protectedBytes = try await relaunched.read(unuploaded, reference: ref())
        assert(protectedBytes == bytes)
        drafts.clear(for: ref())
        try await relaunched.remove(current) { try !drafts.referencedAttachmentIDs(for: ref()).contains(unuploaded.id) }
        let stillThere = try await relaunched.read(attachment, reference: ref())
        assert(stillThere == bytes)
        assert(entry.attachment == attachment)
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
        try Data("corrupt".utf8).write(to: file)
        do { _ = try await relaunched.read(attachment, reference: ref()); assertionFailure("Corrupt source accepted") } catch {}
        let brokenListing = try await relaunched.retained(in: ref().scope)
        assert(brokenListing.hasUnreadableFiles)
        let imported = ChatAttachment(id: "imported-host-file", name: "draft.txt", mediaType: "text/plain", size: UInt64(bytes.count))
        try await relaunched.keep(imported, data: bytes, reference: ref())
        let importedRead = try await ChatLocalAttachmentStore(directory: root).read(imported, reference: ref())
        assert(importedRead == bytes, "Explicitly imported host files remain available offline")
        print("Local attachments: offline relaunch, full ownership, shared upload, durable host mapping and corruption passed")
    }
}
