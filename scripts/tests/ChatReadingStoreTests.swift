// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatReadingStore.swift
// ChatReadingPosition.swift.
import Foundation

@main struct ChatReadingStoreTests {
    @MainActor static func main() {
        let name = "ChatReadingStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChatReadingStore(defaults: defaults)
        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!
        func chat(_ scope: WorkReference.Scope = alice, host: String = "host-a",
                  folder: String = "folder-1", id: String) -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: folder,
                          kind: .conversation, itemID: id)
        }
        func mark(_ event: String, _ offset: Double = 0.25,
                  _ when: Date = Date()) -> ChatReadingMark {
            ChatReadingMark(eventID: event, offset: offset, updatedAt: when)
        }

        // A place is kept per conversation, on one machine, under one account.
        store.remember(mark("s4096"), for: chat(id: "chat-a"))
        assert(store.mark(for: chat(id: "chat-a"))?.eventID == "s4096")
        assert(store.mark(for: chat(id: "chat-b")) == nil)
        assert(store.mark(for: chat(host: "host-b", id: "chat-a")) == nil)
        assert(store.mark(for: chat(folder: "folder-2", id: "chat-a")) == nil)
        assert(store.mark(for: chat(bob, id: "chat-a")) == nil)

        // And survives a relaunch, offset and all.
        let relaunched = ChatReadingStore(defaults: defaults)
        assert(relaunched.mark(for: chat(id: "chat-a"))?.offset == 0.25)

        // Only a row the host named. A row named by its position in a page is
        // a different row on the next page, so it is never kept.
        assert(ChatReadingMark.isStable(eventID: "s0"))
        for kind in ["user", "text", "think", "handoff", "turn", "usage", "failed", "tool", "edit"] {
            assert(ChatReadingMark.isStable(eventID: "\(kind)-s4096"))
            assert(!ChatReadingMark.isStable(eventID: "\(kind)-1234-5"))
        }
        assert(!ChatReadingMark.isStable(eventID: "tool-call-id#2"))
        assert(!ChatReadingMark.isStable(eventID: "s١٢"))
        store.remember(mark("text-s4096"), for: chat(id: "rendered"))
        assert(ChatReadingStore(defaults: defaults).mark(for: chat(id: "rendered"))?.eventID == "text-s4096")
        assert(!ChatReadingMark.isStable(eventID: "s"))
        assert(!ChatReadingMark.isStable(eventID: "1757404800000-12"))
        assert(!ChatReadingMark.isStable(eventID: "sx12"))
        store.remember(mark("1757404800000-12"), for: chat(id: "chat-c"))
        assert(store.mark(for: chat(id: "chat-c")) == nil)

        // Wire keys are the ones a host record would use.
        let wire = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(mark("s1"))) as! [String: Any]
        assert(wire["eventId"] as? String == "s1")

        // Back with the latest turn, or the conversation is gone: no record.
        store.forget(for: chat(id: "chat-a"))
        assert(store.mark(for: chat(id: "chat-a")) == nil)

        // A folder that has left, and an account that has signed out, take
        // their places with them and leave everyone else's alone.
        store.remember(mark("s1"), for: chat(id: "chat-a"))
        store.remember(mark("s2"), for: chat(folder: "folder-2", id: "chat-a"))
        store.remember(mark("s3"), for: chat(bob, id: "chat-a"))
        store.remove(scope: alice, hostIdentity: "host-a", workspaceID: "folder-1")
        assert(store.mark(for: chat(id: "chat-a")) == nil)
        assert(store.mark(for: chat(folder: "folder-2", id: "chat-a"))?.eventID == "s2")
        assert(store.mark(for: chat(bob, id: "chat-a"))?.eventID == "s3")
        store.remove(scope: alice)
        assert(store.mark(for: chat(folder: "folder-2", id: "chat-a")) == nil)
        assert(store.mark(for: chat(bob, id: "chat-a"))?.eventID == "s3")

        // Bounded, newest kept.
        for n in 0..<400 {
            store.remember(mark("s\(n)", 0.1, Date(timeIntervalSince1970: Double(n))),
                           for: chat(id: "chat-\(n)"))
        }
        assert(store.mark(for: chat(id: "chat-0")) == nil)
        assert(store.mark(for: chat(id: "chat-399"))?.eventID == "s399")

        // Damage reads as no place at all, never as a place in the wrong row.
        defaults.set(Data("corrupt".utf8), forKey: "chat.reading.v1")
        assert(store.mark(for: chat(id: "chat-399")) == nil)

        // What the geometry means. With the latest turn is not a place;
        // above it is, and only when a row has said where it is.
        let when = Date(timeIntervalSince1970: 1_000)
        assert(ChatReadingPosition.from(atEnd: true, pinned: true, anchorID: "s7",
                                        anchorTop: 0, anchorHeight: 44, viewportHeight: 800) == .latest)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: nil,
                                        anchorTop: 0, anchorHeight: 0, viewportHeight: 800) == .unknown)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: 0, anchorHeight: 44, viewportHeight: 0) == .unknown)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "12-3",
                                        anchorTop: 0, anchorHeight: 44, viewportHeight: 800) == .unknown)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: 200, anchorHeight: 44, viewportHeight: 800, at: when)
            == .away(mark("s7", 0.25, when)))
        // A row whose top has scrolled past the viewport's edge means the
        // reader is inside the row itself, so the mark keeps how far down
        // it they are. Near the top that is still roughly the top edge;
        // halfway down a long message reopens in its middle.
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: -40, anchorHeight: 800, viewportHeight: 800, at: when)
            == .away(ChatReadingMark(eventID: "s7", offset: 0, updatedAt: when, within: 0.05)))
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: -400, anchorHeight: 800, viewportHeight: 800, at: when)
            == .away(ChatReadingMark(eventID: "s7", offset: 0, updatedAt: when, within: 0.5)))
        // At the end but no longer following it (a page landed above, or the
        // reader paused): still a place worth keeping.
        assert(ChatReadingPosition.from(atEnd: true, pinned: false, anchorID: "s9",
                                        anchorTop: 80, anchorHeight: 44, viewportHeight: 800, at: when)
            == .away(mark("s9", 0.1, when)))

        // A record written before `within` existed still opens at the row's
        // top rather than failing to decode into no place at all.
        let legacyJSON = """
            {"k":{"eventId":"s3","offset":0.2,"updatedAt":\(when.timeIntervalSinceReferenceDate)}}
            """.data(using: .utf8)!
        assert((try! JSONSerialization.jsonObject(with: legacyJSON) as! [String: [String: Any]])["k"]?["within"] == nil)
        let revived = try! JSONDecoder().decode([String: ChatReadingMark].self, from: legacyJSON)
        assert(revived["k"] == ChatReadingMark(eventID: "s3", offset: 0.2, updatedAt: when))

        let target = chat(id: "explicit")
        store.remember(mark("s100"), for: target)
        assert(store.takeRequest(for: target) == nil, "passive history must not move a normal open")
        store.request(mark("s110"), for: target)
        assert(store.takeRequest(for: chat(bob, id: "explicit")) == nil)
        assert(store.takeRequest(for: target)?.eventID == "s110")
        assert(store.takeRequest(for: target) == nil, "explicit navigation is consumed once")
        store.request(mark("s115"), for: target)
        store.forget(for: target)
        assert(store.takeRequest(for: target)?.eventID == "s115", "passive geometry must not erase explicit navigation")
        store.request(mark("s120"), for: target)
        store.remove(scope: alice)
        assert(store.takeRequest(for: target) == nil, "sign-out clears pending navigation")
        store.request(mark("s130"), for: target)
        store.requestLatest(for: target)
        assert(store.takeRequest(for: target) == nil, "latest cancels a pending anchor")

        print("Chat reading: per-conversation places, stable rows only, scope removal, bounds, corruption and geometry passed")
    }
}
