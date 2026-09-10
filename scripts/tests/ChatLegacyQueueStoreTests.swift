// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatLegacyQueueStore.swift.
import Foundation

struct ChatAttachment: Codable, Equatable, Sendable { let id: String; let name: String }

@main struct ChatLegacyQueueStoreTests {
    static func main() throws {
        let suite = "legacy-queue-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "chat.queuedMessages.v1.same-conversation"
        let original = ChatLegacyQueueStore.Message(id: "one", text: "Keep these words", attachments: [])
        let second = ChatLegacyQueueStore.Message(id: "two", text: "Keep these too", attachments: [])
        let bytes = try JSONEncoder().encode([original, second])
        defaults.set(bytes, forKey: key)
        defaults.set(Data("broken".utf8), forKey: "chat.queuedMessages.v1.unreadable")
        defaults.set("unrelated", forKey: "other-setting")
        let listing = ChatLegacyQueueStore.list(defaults: defaults)
        assert(listing.drafts.count == 2 && listing.unreadable == 1)
        assert(defaults.data(forKey: key) == bytes, "listing never adopts, rewrites or removes unassigned writing")
        let selected = listing.drafts.first { $0.message.id == original.id }!
        let edited = ChatLegacyQueueStore.Message(id: "one", text: "Newer writing", attachments: [])
        let newer = try JSONEncoder().encode([edited, second])
        defaults.set(newer, forKey: key)
        do {
            try ChatLegacyQueueStore.remove(selected, defaults: defaults)
            assertionFailure("a stale recovery action must not remove new writing")
        } catch {}
        assert(defaults.data(forKey: key) == newer)
        let current = ChatLegacyQueueStore.list(defaults: defaults).drafts.first { $0.message.id == "one" }!
        try ChatLegacyQueueStore.remove(current, defaults: defaults)
        let remaining = ChatLegacyQueueStore.list(defaults: defaults)
        assert(remaining.drafts.map(\.message) == [second] && remaining.unreadable == 1)
        assert(defaults.string(forKey: "other-setting") == "unrelated")
        assert(defaults.data(forKey: "chat.queuedMessages.v1.unreadable") == Data("broken".utf8))
        print("Legacy queue recovery: read-only listing, exact removal, newer edits and corrupt records passed")
    }
}
