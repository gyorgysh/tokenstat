// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatDraftStore.swift OriginalFileCoordination.swift.
// ChatDraftTransition.swift ChatDraftSubmission.swift.
import Foundation

/// The real one lives in Models.swift, which this test does not need.
struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var mediaType: String?
    var size: UInt64?
}

/// A box, because `withObservationTracking`'s callback may not capture a
/// mutable local in Swift 6 concurrency checking.
final class Notified: @unchecked Sendable {
    var fired = false
}

@main struct ChatDraftStoreTests {
    @MainActor static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "draft-writer" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let author = CommandLine.arguments[3]
            let store = ChatDraftStore(directory: directory)
            let scope = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
            for index in 0..<25 {
                let reference = WorkReference(scope: scope, hostIdentity: "host-a", workspaceID: "folder-1",
                    kind: .conversation, itemID: "\(author)-\(index)")
                store.save(text: "\(author)-\(index)", attachments: [], for: reference)
                store.settle()
                assert(!store.saveFailed)
            }
            return
        }
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

        // A mark belongs to one conversation, on one machine, under one
        // account, and to no other.
        relaunched.save(text: "second", attachments: [], for: reference(chat: "chat-b"))
        relaunched.save(text: "someone else", attachments: [], for: reference(bob, chat: "chat-d"))
        assert(relaunched.hasDraft(for: reference(chat: "chat-a")))
        assert(relaunched.hasDraft(for: reference(chat: "chat-b")))
        assert(!relaunched.hasDraft(for: reference(chat: "chat-c")))
        assert(!relaunched.hasDraft(for: reference(host: "host-b", chat: "chat-a")))
        assert(!relaunched.hasDraft(for: reference(folder: "folder-2", chat: "chat-a")))
        assert(relaunched.hasDraft(for: reference(bob, chat: "chat-d")))
        assert(!relaunched.hasDraft(for: reference(chat: "chat-d")))

        // **The mark only moves when it moves.** Editing a draft that is
        // already marked must notify nothing: a set mutated in place cannot
        // compare itself, so re-inserting a key that is already there
        // notifies every observer. That laid the whole Mac window out again
        // on every pause in typing, with a chat transcript inside it, and
        // hung the app for 25 seconds. See the 2026-09-09 hang.
        func notifies(_ mutate: () -> Void) -> Bool {
            let box = Notified()
            withObservationTracking { _ = relaunched.occupied } onChange: { box.fired = true }
            mutate()
            return box.fired
        }
        let marked = reference(chat: "already-marked")
        assert(notifies { relaunched.save(text: "one", attachments: [], for: marked) },
               "the first words in a conversation mark it")
        assert(!notifies { relaunched.save(text: "one, edited", attachments: [], for: marked) },
               "editing a marked conversation must not notify")
        assert(!notifies { relaunched.save(text: "one, edited again", attachments: [file], for: marked) },
               "attaching to a marked conversation must not notify")
        assert(notifies { relaunched.clear(for: marked) },
               "sending the words takes the mark with them")
        assert(!notifies { relaunched.clear(for: marked) },
               "clearing what is already clear must not notify")

        // Separators inside an id cannot make two conversations one.
        let awkward = reference(folder: "a|b", chat: "c")
        let alsoAwkward = reference(folder: "a", chat: "b|c")
        relaunched.save(text: "first", attachments: [], for: awkward)
        relaunched.save(text: "second", attachments: [], for: alsoAwkward)
        assert(relaunched.draft(for: awkward)?.text == "first")
        assert(relaunched.draft(for: alsoAwkward)?.text == "second")
        assert(relaunched.hasDraft(for: awkward))
        assert(!relaunched.hasDraft(for: reference(folder: "a|b", chat: "b")))

        // Emptying the composer removes the record rather than storing nothing.
        relaunched.save(text: "   \n ", attachments: [], for: reference(chat: "chat-b"))
        assert(relaunched.draft(for: reference(chat: "chat-b")) == nil)
        assert(!relaunched.hasDraft(for: reference(chat: "chat-b")))
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

        // Original-file cleanup protects both a window's unsaved view and
        // the latest persisted attachment references from another window.
        let fileRef = reference(chat: "original-files")
        windowOne.save(text: "original", attachments: [file], for: fileRef)
        windowOne.settle()
        let fileWindow = ChatDraftStore(directory: root)
        let nextFile = ChatAttachment(id: "file-2", name: "new.txt", mediaType: "text/plain", size: 4)
        windowOne.save(text: "changed", attachments: [nextFile], for: fileRef)
        windowOne.settle()
        assert(try! fileWindow.referencedAttachmentIDs(for: fileRef) == Set([file.id, nextFile.id]))
        let protectedFiles = try! fileWindow.protectedAttachments(in: alice)
        assert(protectedFiles[WorkReferenceKey.conversation(fileRef)!] == Set([file.id, nextFile.id]))
        assert((try! fileWindow.protectedAttachments(in: bob))[WorkReferenceKey.conversation(fileRef)!] == nil)

        // A late acknowledgement must not remove another window's edit.
        let receiptRef = reference(chat: "late-receipt")
        windowOne.save(text: "submitted", attachments: [], for: receiptRef)
        windowOne.settle()
        let acknowledged = windowOne.draft(for: receiptRef)!
        let editingWindow = ChatDraftStore(directory: root)
        editingWindow.save(text: "new writing", attachments: [], for: receiptRef, newMessage: true)
        editingWindow.settle()
        windowOne.clear(acknowledged)
        windowOne.settle()
        assert(ChatDraftStore(directory: root).draft(for: receiptRef)?.text == "new writing")
        let currentDraft = editingWindow.draft(for: receiptRef)!
        editingWindow.save(text: "another edit", attachments: [], for: receiptRef)
        editingWindow.clear(currentDraft)
        editingWindow.settle()
        assert(ChatDraftStore(directory: root).draft(for: receiptRef)?.text == "another edit")

        // An old window edits only its own changed keys. It cannot revive
        // another window's deletion or overwrite that window's newer words.
        let stale = ChatDraftStore(directory: root)
        windowOne.save(text: "newer", attachments: [], for: reference(chat: "one"))
        windowTwo.clear(for: reference(chat: "two"))
        windowTwo.settle()
        stale.save(text: "unrelated", attachments: [], for: reference(chat: "three"))
        stale.settle()
        let afterStale = ChatDraftStore(directory: root)
        assert(afterStale.draft(for: reference(chat: "one"))?.text == "newer")
        assert(afterStale.draft(for: reference(chat: "two")) == nil)

        // Hundreds of unsent conversations remain user data, regardless of age.
        let manyRoot = root.appendingPathComponent("many")
        let many = ChatDraftStore(directory: manyRoot)
        for n in 0..<405 {
            many.save(text: "draft \(n)", attachments: [], for: reference(chat: "many-\(n)"))
        }
        many.settle()
        let manyAgain = ChatDraftStore(directory: manyRoot)
        assert(!many.saveFailed && manyAgain.occupied.count == 405)
        assert(manyAgain.draft(for: reference(chat: "many-0"))?.text == "draft 0")
        let longText = String(repeating: "a", count: 200_001) + "end 🪻"
        many.save(text: longText, attachments: [], for: reference(chat: "long"))
        many.settle()
        assert(ChatDraftStore(directory: manyRoot).draft(for: reference(chat: "long"))?.text == longText)

        // A full store refuses the whole update, leaves the previous file
        // readable, and keeps the complete new draft in memory for recovery.
        let boundedRoot = root.appendingPathComponent("bounded")
        let bounded = ChatDraftStore(directory: boundedRoot, byteLimit: 2048)
        let boundedReference = reference(chat: "bounded")
        bounded.save(text: "saved", attachments: [], for: boundedReference)
        bounded.settle()
        assert(!bounded.saveFailed)
        let overLimit = String(repeating: "x", count: 3000)
        bounded.save(text: overLimit, attachments: [], for: boundedReference)
        bounded.settle()
        assert(bounded.saveFailed)
        assert(bounded.draft(for: boundedReference)?.text == overLimit)
        assert(ChatDraftStore(directory: boundedRoot).draft(for: boundedReference)?.text == "saved")
        bounded.save(text: "fits again", attachments: [], for: boundedReference)
        bounded.settle()
        assert(!bounded.saveFailed)
        assert(ChatDraftStore(directory: boundedRoot).draft(for: boundedReference)?.text == "fits again")

        // A failed deletion survives Retry instead of being read back from
        // the old file. Another edit cannot accidentally restore it either.
        let boundedPath = boundedRoot.appendingPathComponent("drafts.v1.json")
        let savedBeforeFailure = try! Data(contentsOf: boundedPath)
        try! FileManager.default.removeItem(at: boundedPath)
        try! FileManager.default.createDirectory(at: boundedPath, withIntermediateDirectories: false)
        bounded.clear(for: boundedReference)
        bounded.settle()
        assert(bounded.saveFailed)
        try! FileManager.default.removeItem(at: boundedPath)
        try! savedBeforeFailure.write(to: boundedPath)
        bounded.retryFailedSave()
        bounded.settle()
        assert(!bounded.saveFailed)
        assert(ChatDraftStore(directory: boundedRoot).draft(for: boundedReference) == nil)

        // A damaged file must survive failed writes for recovery. Once the
        // original file is restored, retry merges the new writing into it.
        let path = root.appendingPathComponent("drafts.v1.json")
        let beforeCorruption = try! Data(contentsOf: path)
        let damaged = Data("not json".utf8)
        try! damaged.write(to: path)
        let afterCorruption = ChatDraftStore(directory: path.deletingLastPathComponent())
        assert(afterCorruption.draft(for: reference(chat: "one")) == nil)
        assert(!afterCorruption.hasDraft(for: reference(chat: "one")))
        afterCorruption.save(text: "after", attachments: [], for: reference(chat: "three"))
        afterCorruption.settle()
        assert(afterCorruption.saveFailed)
        assert(try! Data(contentsOf: path) == damaged)
        assert(afterCorruption.draft(for: reference(chat: "three"))?.text == "after")
        try! beforeCorruption.write(to: path)
        afterCorruption.retryFailedSave()
        assert(afterCorruption.saveFailed, "Retry does not claim success before the write")
        afterCorruption.settle()
        assert(!afterCorruption.saveFailed)
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
        // An explicit handoff import is a fresh local send identity, even if
        // its words and files happen to match the existing draft exactly.
        afterCorruption.save(text: "first, edited", attachments: [file], for: named, newMessage: true)
        let importedID = afterCorruption.draft(for: named)?.messageID
        assert(importedID != nil && importedID != minted)
        afterCorruption.settle()
        let reopenedImport = ChatDraftStore(directory: root).draft(for: named)
        assert(reopenedImport?.messageID == importedID)
        assert(reopenedImport?.text == "first, edited" && reopenedImport?.attachments == [file])
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
            attachments: sendingDraft.attachments, messageID: sendingDraft.messageID, expectedRevision: 9)
        assert(submission.expectedRevision == 9)
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

        let processRoot = root.appendingPathComponent("processes", isDirectory: true)
        var children: [Process] = []
        for author in 0..<4 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["draft-writer", processRoot.path, "writer-\(author)"]
            try! child.run()
            children.append(child)
        }
        for child in children {
            child.waitUntilExit()
            assert(child.terminationStatus == 0)
        }
        let concurrent = ChatDraftStore(directory: processRoot)
        assert(concurrent.drafts(in: alice).count == 100)
        for author in 0..<4 {
            for index in 0..<25 {
                let id = "writer-\(author)-\(index)"
                assert(concurrent.draft(for: reference(chat: id))?.text == id)
            }
        }
        print("Chat drafts: ownership, relaunch, process merge, removal, corruption, quiet marks, message names and composer transitions passed")
    }
}
