// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkCache.swift.
import Foundation

@main struct WorkCacheTests {
    static func main() {
        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        func conversation(host: String = "host-a", folder: String = "folder-1",
                          chat: String = "chat-a") -> WorkReference {
            WorkReference(scope: alice, hostIdentity: host, workspaceID: folder,
                          kind: .conversation, itemID: chat)
        }

        // One scope per account, shared by every machine and folder under it:
        // signing out removes one scope and takes exactly its copies.
        assert(WorkCache.scope(for: alice) == "account|https%3A%2F%2Fexample%2Ecom|alice")
        // One record per conversation inside it.
        assert(WorkCache.recordID(for: conversation()) == "conv|host%2Da|folder%2D1|chat%2Da")
        // Nothing without a conversation is a record.
        let workspace = WorkReference(scope: alice, hostIdentity: "host-a",
            workspaceID: "folder-1", kind: .workspace, itemID: nil)
        assert(WorkCache.recordID(for: workspace) == nil)
        // Separators inside an id cannot merge two conversations.
        let awkward = conversation(folder: "a|b", chat: "c")
        let alsoAwkward = conversation(folder: "a", chat: "b|c")
        assert(WorkCache.recordID(for: awkward) != WorkCache.recordID(for: alsoAwkward))

        for reference in [conversation(), awkward, alsoAwkward,
                          conversation(host: "machine|one", folder: "a:b/é", chat: "消息")] {
            assert(WorkCache.reference(recordID: WorkCache.recordID(for: reference)!, scope: alice) == reference)
        }
        for invalid in ["conv|host|folder", "conv||folder|chat", "conv|host|folder|", "conv|host|%ZZ|chat",
                        "other|host|folder|chat", "conv|host|folder|chat|extra"] {
            assert(WorkCache.reference(recordID: invalid, scope: alice) == nil)
        }

        // Two pages with the same revision show the same conversation.
        assert(WorkCache.revision(maxSeq: 9, count: 2, nextOffset: 42) == "s9:2:42")
        assert(WorkCache.revision(maxSeq: 9, count: 3, nextOffset: 42) != "s9:2:42")
        // Reconnecting compares the saved revision against the fresh page: a
        // match means the conversation was quiet, anything else replaces it.
        assert(WorkCache.matches("s9:2:42", maxSeq: 9, count: 2, nextOffset: 42))
        assert(!WorkCache.matches("s9:2:42", maxSeq: 10, count: 3, nextOffset: 43))

        // The envelope carries the title, the revision and the page, and
        // reads back what was written. A damaged envelope is an error rather
        // than a copy with no title or no page.
        let page: [String: Any] = [
            "events": [["kind": "user", "text": "hello", "seq": 7]],
            "nextOffset": 42, "hasEarlier": true,
        ]
        let payload = try! WorkCache.encode(title: "Weekend plans", revision: "s9:2:42", page: page)
        assert(payload["title"] as? String == "Weekend plans")
        assert(payload["revision"] as? String == "s9:2:42")
        let revived = try! WorkCache.decode(payload)
        assert(revived.title == "Weekend plans" && revived.revision == "s9:2:42")
        assert((revived.page["events"] as? [[String: Any]])?.count == 1)
        assert(revived.page["hasEarlier"] as? Bool == true)
        assert((try? WorkCache.decode(["title": "x"])) == nil)
        assert((try? WorkCache.decode(["title": "x", "savedAt": "not a date",
                                        "revision": "s", "page": page])) == nil)

        // Keeping copies is on until it is turned off, and off stays off.
        let name = "WorkCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = WorkCacheSettings(defaults: defaults)
        assert(settings.enabled)
        settings.enabled = false
        assert(!WorkCacheSettings(defaults: defaults).enabled)

        print("Work cache: scopes, record ids, revisions, envelopes and settings passed")
    }
}
