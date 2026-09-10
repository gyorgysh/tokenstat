// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatLocalAttachmentStore.swift.
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
@main struct ChatLocalAttachmentStoreTests {
    static func main() async throws {
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
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        try Data("corrupt".utf8).write(to: file)
        do { _ = try await relaunched.read(attachment, reference: ref()); assertionFailure("Corrupt source accepted") } catch {}
        let imported = ChatAttachment(id: "imported-host-file", name: "draft.txt", mediaType: "text/plain", size: UInt64(bytes.count))
        try await relaunched.keep(imported, data: bytes, reference: ref())
        let importedRead = try await ChatLocalAttachmentStore(directory: root).read(imported, reference: ref())
        assert(importedRead == bytes, "Explicitly imported host files remain available offline")
        print("Local attachments: offline relaunch, full ownership, shared upload, durable host mapping and corruption passed")
    }
}
