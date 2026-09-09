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
                                        anchorTop: 0, viewportHeight: 800) == .latest)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: nil,
                                        anchorTop: 0, viewportHeight: 800) == .unknown)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: 0, viewportHeight: 0) == .unknown)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "12-3",
                                        anchorTop: 0, viewportHeight: 800) == .unknown)
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: 200, viewportHeight: 800, at: when)
            == .away(mark("s7", 0.25, when)))
        // A row scrolled off the top reads as the top edge, never as a
        // negative fraction that would place it off screen next time.
        assert(ChatReadingPosition.from(atEnd: false, pinned: false, anchorID: "s7",
                                        anchorTop: -40, viewportHeight: 800, at: when)
            == .away(mark("s7", 0, when)))
        // At the end but no longer following it (a page landed above, or the
        // reader paused): still a place worth keeping.
        assert(ChatReadingPosition.from(atEnd: true, pinned: false, anchorID: "s9",
                                        anchorTop: 80, viewportHeight: 800, at: when)
            == .away(mark("s9", 0.1, when)))

        print("Chat reading: per-conversation places, stable rows only, scope removal, bounds, corruption and geometry passed")
    }
}
