// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatOutboxStore.swift. OriginalFileCoordination.swift.
import Foundation

struct ChatAttachment: Codable, Equatable, Sendable { let id: String; let name: String }

@main struct ChatOutboxStoreTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ChatOutboxStore(directory: root)
        let second = ChatOutboxStore(directory: root)
        let scope = WorkReference.Scope.local(installationID: "one")
        func ref(_ host: String = "host-a", scope: WorkReference.Scope = scope) -> WorkReference {
            .init(scope: scope, hostIdentity: host, workspaceID: "folder", kind: .conversation, itemID: "same-chat")
        }
        let message = ChatQueuedMessage(id: "stable-message", text: "Original words", attachments: [])
        try first.update(ref()) { $0.append(message) }
        try second.update(ref("host-b")) { $0.append(message) }
        let checked1 = try first.items(for: ref()).count == 1
        assert(checked1)
        let checked2 = try second.items(for: ref("host-b")).count == 1
        assert(checked2)
        let checked3 = try first.items(for: ref(scope: .local(installationID: "other"))).isEmpty
        assert(checked3)
        // Two window instances merge against disk rather than a cached table.
        try second.update(ref()) { $0[0].text = "Edited in another window" }
        let checked4 = try first.items(for: ref())[0].text == "Edited in another window"
        assert(checked4)
        try first.update(ref()) { $0[0].expectedRevision = 7; $0[0].delivery = .sending; $0[0].firstAttemptAt = Date(timeIntervalSince1970: 40); $0[0].attemptedAt = Date(timeIntervalSince1970: 42) }
        let reopened = ChatOutboxStore(directory: root)
        let held = try reopened.items(for: ref())[0]
        assert(held.id == message.id && held.needsReceipt && !held.canEdit)
        assert(held.attemptedAt == Date(timeIntervalSince1970: 42))
        assert(held.expectedRevision == 7)
        assert(held.firstAttemptAt == Date(timeIntervalSince1970: 40))
        // Existing persisted messages have no firstAttemptAt. They remain
        // readable and retain attemptedAt for the protocol migration.
        let legacy = Data(#"{"id":"legacy","text":"keep me","attachments":[],"delivery":"failed","attemptedAt":42,"whenConnected":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatQueuedMessage.self, from: legacy)
        assert(decoded.expectedRevision == nil)
        assert(decoded.firstAttemptAt == nil && decoded.attemptedAt != nil)
        assert(first.beginDelivery(ref()))
        assert(!first.beginDelivery(ref()))
        first.endDelivery(ref())
        assert(first.beginDelivery(ref()))
        first.endDelivery(ref())
        // Explicit offline enrollment survives relaunch without turning an
        // uncertain delivery back into a waiting message.
        try first.update(ref("host-b")) { $0[0].whenConnected = true; $0[0].sourceDraftText = "Original words" }
        let enrolled = try reopened.items(for: ref("host-b"))[0]
        assert(enrolled.whenConnected && enrolled.delivery == .waiting)
        assert(enrolled.sourceDraftText == "Original words")
        try first.update(ref("host-b")) { $0[0].delivery = .deliveryUnknown }
        let uncertain = try reopened.items(for: ref("host-b"))[0]
        assert(uncertain.whenConnected && uncertain.needsReceipt && !uncertain.canEdit)
        // A rejected write cannot delete a previously persisted message.
        let small = ChatOutboxStore(directory: root, byteLimit: 16)
        do { try small.update(ref()) { $0.removeAll() }; assertionFailure("Overwrote an unreadable file") }
        catch {}
        let checked5 = try reopened.items(for: ref()).count == 1
        assert(checked5)
        try reopened.update(ref()) { $0.removeAll { $0.id == held.id } }
        let checked6 = try first.items(for: ref()).isEmpty
        assert(checked6)
        let checked7 = try first.items(for: ref("host-b")).count == 1
        assert(checked7)
        // Our acknowledged turn advances its untouched successors only.
        let sequence = ref("sequence")
        var accepted = message
        accepted.expectedRevision = 5
        var successor = ChatQueuedMessage(id: "next", text: "Next words", attachments: [])
        successor.expectedRevision = 5
        var otherContext = successor
        otherContext.id = "other-context"
        otherContext.expectedRevision = 4
        var review = successor
        review.id = "review"
        review.delivery = .needsReview
        try first.update(sequence) { $0 = [accepted, successor, otherContext, review] }
        let advanced = try first.accept(accepted, revision: 6, for: sequence)
        assert(advanced.map(\.expectedRevision) == [6, 4, 5])
        let persistedSequence = try reopened.items(for: sequence)
        assert(persistedSequence == advanced)
        try first.update(sequence) { $0 = [accepted, successor] }
        let unrelated = try first.accept(accepted, revision: 8, for: sequence)
        assert(unrelated[0].expectedRevision == 5)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("outbox.v1.json").path)[.posixPermissions] as? NSNumber
        assert(mode?.intValue == 0o600)
        print("Outbox: durable delivery state, host/account isolation, merged window edits, delivery ownership, failed-write preservation and private files passed")
    }
}
