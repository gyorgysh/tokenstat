// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatDraftStore.swift
// ChatDraftTransition.swift ChatDraftSubmission.swift.
import Foundation

/// The real one lives in Models.swift, which this test does not need.
struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var mediaType: String?
    var size: UInt64?
}

@main struct ChatDraftStoreTests {
    @MainActor static func main() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!
        func reference(_ scope: WorkReference.Scope = alice, host: String = "host-a",
                       folder: String = "folder-1", chat: String) -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: folder,
                          kind: .conversation, itemID: chat)
        }
        let file = ChatAttachment(id: "file-1", name: "notes.md", mediaType: "text/markdown", size: 12)

        // Words survive a relaunch, with the files staged beside them.
        let store = ChatDraftStore(directory: root)
        store.save(text: "half a thought", attachments: [file], for: reference(chat: "chat-a"))
        store.settle()
        let relaunched = ChatDraftStore(directory: root)
        let restored = relaunched.draft(for: reference(chat: "chat-a"))
        assert(restored?.text == "half a thought")
        assert(restored?.attachments == [file])

        // And belong to one conversation, on one machine, under one account.
        assert(relaunched.draft(for: reference(chat: "chat-b")) == nil)
        assert(relaunched.draft(for: reference(host: "host-b", chat: "chat-a")) == nil)
        assert(relaunched.draft(for: reference(folder: "folder-2", chat: "chat-a")) == nil)
        assert(relaunched.draft(for: reference(bob, chat: "chat-a")) == nil)

        // A list marks the conversations that hold words, and no others.
        relaunched.save(text: "second", attachments: [], for: reference(chat: "chat-b"))
        relaunched.save(text: "elsewhere", attachments: [], for: reference(folder: "folder-2", chat: "chat-c"))
        relaunched.save(text: "someone else", attachments: [], for: reference(bob, chat: "chat-d"))
        assert(relaunched.conversationsWithDrafts(scope: alice, hostIdentity: "host-a",
            workspaceID: "folder-1") == ["chat-a", "chat-b"])
        assert(relaunched.conversationsWithDrafts(scope: bob, hostIdentity: "host-a",
            workspaceID: "folder-1") == ["chat-d"])
        assert(relaunched.conversationsWithDrafts(scope: alice, hostIdentity: "host-b",
            workspaceID: "folder-1").isEmpty)

        // Separators inside an id cannot make two conversations one.
        let awkward = reference(folder: "a|b", chat: "c")
        let alsoAwkward = reference(folder: "a", chat: "b|c")
        relaunched.save(text: "first", attachments: [], for: awkward)
        relaunched.save(text: "second", attachments: [], for: alsoAwkward)
        assert(relaunched.draft(for: awkward)?.text == "first")
        assert(relaunched.draft(for: alsoAwkward)?.text == "second")
        assert(relaunched.conversationsWithDrafts(scope: alice, hostIdentity: "host-a",
            workspaceID: "a|b") == ["c"])

        // Emptying the composer removes the record rather than storing nothing.
        relaunched.save(text: "   \n ", attachments: [], for: reference(chat: "chat-b"))
        assert(relaunched.draft(for: reference(chat: "chat-b")) == nil)
        assert(!relaunched.conversationsWithDrafts(scope: alice, hostIdentity: "host-a",
            workspaceID: "folder-1").contains("chat-b"))
        relaunched.clear(for: reference(chat: "chat-a"))
        assert(relaunched.draft(for: reference(chat: "chat-a")) == nil)
        relaunched.settle()
        assert(ChatDraftStore(directory: root).draft(for: reference(chat: "chat-a")) == nil)

        // A second window keeps the first one's words: a write merges into
        // what the file already holds rather than replacing it.
        let windowOne = ChatDraftStore(directory: root)
        let windowTwo = ChatDraftStore(directory: root)
        windowOne.save(text: "from one", attachments: [], for: reference(chat: "one"))
        windowOne.settle()
        windowTwo.save(text: "from two", attachments: [], for: reference(chat: "two"))
        windowTwo.settle()
        let merged = ChatDraftStore(directory: root)
        assert(merged.draft(for: reference(chat: "one"))?.text == "from one")
        assert(merged.draft(for: reference(chat: "two"))?.text == "from two")

        // A file somebody replaced with rubbish loses its contents and
        // nothing else: the next save still works.
        let path = root.appendingPathComponent("drafts.v1.json")
        try! Data("not json".utf8).write(to: path)
        let afterCorruption = ChatDraftStore(directory: path.deletingLastPathComponent())
        assert(afterCorruption.draft(for: reference(chat: "one")) == nil)
        assert(afterCorruption.conversationsWithDrafts(scope: alice, hostIdentity: "host-a",
            workspaceID: "folder-1").isEmpty)
        afterCorruption.save(text: "after", attachments: [], for: reference(chat: "three"))
        afterCorruption.settle()
        assert(ChatDraftStore(directory: root).draft(for: reference(chat: "three"))?.text == "after")

        // Nothing without a conversation is a draft.
        let workspace = WorkReference(scope: alice, hostIdentity: "host-a",
            workspaceID: "folder-1", kind: .workspace, itemID: nil)
        afterCorruption.save(text: "no owner", attachments: [], for: workspace)
        assert(afterCorruption.draft(for: workspace) == nil)

        // The name a draft's words travel under is minted once and kept, so
        // sending the same message again is the same message.
        let named = reference(chat: "named")
        afterCorruption.save(text: "first", attachments: [], for: named)
        let minted = afterCorruption.draft(for: named)?.messageID
        assert(minted?.isEmpty == false)
        afterCorruption.save(text: "first, edited", attachments: [file], for: named)
        assert(afterCorruption.draft(for: named)?.messageID == minted)
        afterCorruption.settle()
        assert(ChatDraftStore(directory: root).draft(for: named)?.messageID == minted)
        // A message that was sent takes its name with it: the next one is new.
        afterCorruption.clear(for: named)
        afterCorruption.save(text: "second", attachments: [], for: named)
        assert(afterCorruption.draft(for: named)?.messageID != minted)

        // What the composer does when the screen points somewhere else.
        let one = reference(chat: "one")
        let two = reference(chat: "two")
        assert(ChatDraftTransition.resolve(incoming: "one", reference: one,
            current: "two", currentReference: two) == .swap(one))
        assert(ChatDraftTransition.resolve(incoming: nil, reference: nil,
            current: "two", currentReference: two) == .swap(nil))
        // The identity arrives while somebody is typing: the words stay and
        // gain an owner.
        assert(ChatDraftTransition.resolve(incoming: "one", reference: one,
            current: "one", currentReference: nil) == .adopt(one))
        // Still unknown, still the same conversation: leave the composer alone.
        assert(ChatDraftTransition.resolve(incoming: "one", reference: nil,
            current: "one", currentReference: nil) == .keep)
        // A conversation whose words are already on screen is not reloaded.
        assert(ChatDraftTransition.resolve(incoming: "one", reference: one,
            current: "one", currentReference: one) == .keep)
        // No conversation before and none now is not a change.
        assert(ChatDraftTransition.resolve(incoming: nil, reference: nil,
            current: nil, currentReference: nil) == .keep)
        // A conversation that cannot be keyed still replaces one that could.
        assert(ChatDraftTransition.resolve(incoming: "one", reference: nil,
            current: "two", currentReference: two) == .swap(nil))

        // A lifecycle save while a send is waiting must keep both the words
        // and the original id, including after navigation away and back.
        let sendingReference = reference(chat: "sending")
        afterCorruption.save(text: "with a file", attachments: [file], for: sendingReference)
        let sendingDraft = afterCorruption.draft(for: sendingReference)!
        let submission = ChatDraftSubmission(conversationID: "sending", peer: "host-a",
            scope: alice, reference: sendingReference, generation: 7,
            text: sendingDraft.text, draftText: sendingDraft.text,
            attachments: sendingDraft.attachments, messageID: sendingDraft.messageID)
        func lifecycleSave(_ reference: WorkReference, chat: String, text: String) {
            guard !submission.owns(reference: reference, conversationID: chat,
                                   peer: "host-a", scope: alice) else { return }
            afterCorruption.save(text: text, attachments: [], for: reference)
        }
        lifecycleSave(sendingReference, chat: "sending", text: "")
        lifecycleSave(two, chat: "two", text: "another conversation")
        lifecycleSave(sendingReference, chat: "sending", text: sendingDraft.text)
        afterCorruption.settle()
        let recovery = ChatDraftStore(directory: root).draft(for: sendingReference)
        assert(recovery == sendingDraft)
        assert(afterCorruption.draft(for: two)?.text == "another conversation")
        // Completion can clear the original persisted copy without touching
        // the conversation opened while the request was in flight.
        afterCorruption.clear(for: submission.reference!)
        assert(afterCorruption.draft(for: two)?.text == "another conversation")
        assert(submission.attachments == [file])
        assert(!submission.owns(reference: two, conversationID: "two", peer: "host-a", scope: alice))
        assert(!submission.owns(reference: sendingReference, conversationID: "sending",
                                peer: "host-b", scope: alice))
        assert(!submission.owns(reference: sendingReference, conversationID: "sending",
                                peer: "host-a", scope: bob))
        // Even without resolved draft storage, the peer and account must
        // match before a delayed response restores text to a composer.
        let unresolved = ChatDraftSubmission(conversationID: "same-id", peer: "host-a",
            scope: alice, reference: nil, generation: 8, text: "hello", draftText: "hello",
            attachments: [], messageID: nil)
        assert(!unresolved.owns(reference: nil, conversationID: "same-id", peer: "host-b", scope: alice))
        // A conversation id is only unique within its full owner.
        let otherHost = reference(host: "host-b", chat: "one")
        assert(ChatDraftTransition.resolve(incoming: "one", reference: otherHost,
            current: "one", currentReference: one) == .swap(otherHost))
        assert(ChatDraftTransition.resolve(incoming: "one", reference: nil,
            current: "one", currentReference: one) == .swap(nil))

        print("Chat drafts: ownership, relaunch, merge, removal, corruption, message names and composer transitions passed")
    }
}
