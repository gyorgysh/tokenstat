// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientChatLayoutHandoff.swift ClientChatSession.swift Singleflight.swift ChatDraftTransition.swift WorkReference.swift WorkMobileRoute.swift.
import Foundation
import Observation

struct ChatConversation: Equatable { let id: String; var title: String = "" }

@MainActor
final class ChatModel {
    var busy = false
    var sending = false
    var isCreating = false
    var openingConversation = false
    var unconfirmedSend: String?
    var draft = ""
    var attachments: [String] = []
    var stagingAttachments = 0
    var pendingQueue: [String] = []
    var loads = 0
    var saves = 0
    var onLoad: (() async -> Void)?
    var onSelect: (() async -> Void)?
    var selected: ChatConversation?
    var selectionGeneration: UInt64 = 0
    var currentReference: WorkReference?
    var completedSelections = 0
    var mostRecent: ChatConversation?
    var selections = 0
    var creates = 0
    var error: String?
    var failure: String?
    var peer: String?
    private var workspace: String?
    func isReady(for workspaceID: String) -> Bool { workspace == workspaceID }
    func saveDraftNow() { saves += 1 }
    func acceptRenamedConversation(_ chat: ChatConversation) {
        if selected?.id == chat.id { selected = chat }
    }
    func forgetRemovedConversation(_ id: String) async {
        if selected?.id == id {
            // Real draft transition after the durable reference is detached,
            // retaining the deleted ID until select(nil) swaps the composer.
            if ChatDraftTransition.resolve(incoming: nil, reference: nil,
                current: id, currentReference: nil) == .swap(nil) {
                draft = ""; attachments = []; unconfirmedSend = nil
            }
            selected = nil; busy = false
        }
    }
    func load(workspaceID: String, peer: String, selectFirst: Bool) async {
        loads += 1
        self.peer = peer
        workspace = workspaceID
        await onLoad?()
        if let failure { error = failure }
    }
    func select(_ chat: ChatConversation) async {
        guard !Task.isCancelled else { return }
        selections += 1
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selected = chat
        await onSelect?()
        guard !Task.isCancelled, generation == selectionGeneration else { return }
        completedSelections += 1
    }
    func create() async -> ChatConversation? {
        creates += 1
        let chat = ChatConversation(id: "created")
        await select(chat)
        mostRecent = chat
        return chat
    }
}

@MainActor
private final class Signal {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        ready = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}


@main
struct ClientChatLayoutHandoffTests {
    @MainActor
    static func main() {
        let scope = WorkReference.Scope.account(origin: "https://test.example", handle: "alice")!
        func reference(_ chat: String, peer: String = "mac", workspace: String = "p") -> WorkReference {
            WorkReference(scope: scope, hostIdentity: peer, workspaceID: workspace,
                kind: .conversation, itemID: chat)
        }
        let b = reference("b")
        let bKey = ClientChatSessions.Key(peer: "mac", workspace: "p", conversation: "b")
        let folderKey = ClientChatSessions.Key(peer: "mac", workspace: "p", conversation: nil)
        let route = WorkMobileRoute(scope: scope, tab: "workspaces", reference: b, section: "chat")
        let store = ClientChatSessions(limit: 1)
        let session = store.session(peer: "mac", workspace: "p", conversation: "b")
        session.model.selected = ChatConversation(id: "b")
        session.model.currentReference = b
        session.model.selectionGeneration = 3
        let handoff = ClientChatLayoutHandoff()
        let originalOwner = UUID(), push = UUID()
        precondition(handoff.show(session: session, key: bKey, reference: b, owner: originalOwner,
            folderName: "Project", hostName: "Mac", presentationID: push, intent: 0, handoffID: nil))
        let logicalID = handoff.reader!.id
        // Teardown before root capture still leaves the logical lease pinned.
        session.disappear(originalOwner)
        precondition(!session.canDiscard)
        _ = store.session(peer: "mac", workspace: "intermediate")
        precondition(store.session(peer: "mac", workspace: "p", conversation: "b") === session)
        let first = handoff.begin(route: route)!
        precondition(handoff.isCurrent(first, scope: scope))
        let folderA = ClientChatSession()
        folderA.model.selected = ChatConversation(id: "a")
        folderA.model.currentReference = reference("a")
        precondition(!handoff.show(session: folderA, key: folderKey, reference: reference("a"), owner: UUID(),
            folderName: "Project", hostName: "Mac", presentationID: nil, intent: 0, handoffID: first.id))
        precondition(folderA.model.selected?.id == "a" && handoff.reader?.session === session)
        let nextOwner = UUID()
        precondition(handoff.show(session: session, key: bKey, reference: b, owner: nextOwner,
            folderName: "Project", hostName: "Mac", presentationID: push, intent: 0, handoffID: first.id))
        precondition(handoff.pending == nil && handoff.reader?.id == logicalID)
        session.disappear(originalOwner)
        precondition(!session.canDiscard, "late predecessor teardown cannot release successor or logical lease")

        for _ in 0..<30 {
            let old = handoff.begin(route: route)!
            let newest = handoff.begin(route: route)!
            precondition(!handoff.isCurrent(old, scope: scope))
            precondition(!handoff.show(session: session, key: bKey, reference: b, owner: UUID(),
                folderName: "Project", hostName: "Mac", presentationID: push,
                intent: handoff.intent, handoffID: old.id))
            precondition(handoff.pending?.id == newest.id)
            let owner = UUID()
            precondition(handoff.show(session: session, key: bKey, reference: b, owner: owner,
                folderName: "Project", hostName: "Mac", presentationID: push,
                intent: handoff.intent, handoffID: newest.id))
            precondition(handoff.pending == nil && handoff.reader?.id == logicalID)
            session.disappear(owner)
            _ = store.session(peer: "mac", workspace: "intermediate")
            precondition(store.session(peer: "mac", workspace: "p", conversation: "b") === session)
        }
        let latest = handoff.begin(route: route)!
        handoff.chooseViewport(model: session.model)
        precondition(!handoff.isCurrent(latest, scope: scope) && handoff.reader?.session === session)
        session.model.selectionGeneration &+= 1
        let afterLatest = handoff.begin(route: route)!
        precondition(handoff.isCurrent(afterLatest, scope: scope), "Latest keeps provenance for the next fold")
        // Opening and dismissing isolated notification C preserve B underneath.
        handoff.suspend()
        precondition(handoff.reader?.session === session && handoff.pending == nil)
        handoff.suspend()
        let afterCover = handoff.begin(route: route)!
        precondition(handoff.isCurrent(afterCover, scope: scope) && afterCover.reader.key == bKey)
        handoff.navigate()
        precondition(handoff.reader == nil && handoff.pending == nil, "real Back retires the logical reader")
        precondition(handoff.begin(route: route) == nil, "Back then fold must not reopen the closed chat")
        session.disappear(nextOwner)
        precondition(session.canDiscard)

        // Folder fallback retains conversation:nil even with no metadata.
        let folder = ClientChatSession()
        folder.model.selected = ChatConversation(id: "b")
        folder.model.currentReference = b
        let fallback = ClientChatLayoutHandoff(), folderOwner = UUID()
        precondition(fallback.show(session: folder, key: folderKey, reference: b, owner: folderOwner,
            folderName: "", hostName: "", presentationID: nil, intent: 0, handoffID: nil))
        folder.disappear(folderOwner)
        let missingMetadata = fallback.begin(route: route)!
        precondition(missingMetadata.reader.key.conversation == nil && missingMetadata.reader.session === folder)
        precondition(missingMetadata.reader.folderName.isEmpty && missingMetadata.reader.hostName.isEmpty)
        precondition(!folder.canDiscard)
        precondition(!fallback.isCurrent(missingMetadata, scope: .local(installationID: "other")))
        folder.model.selectionGeneration &+= 1
        precondition(!fallback.isCurrent(missingMetadata, scope: scope), "changed selection rejects late delivery")
        precondition(!fallback.show(session: folder, key: folderKey, reference: b, owner: UUID(),
            folderName: "", hostName: "", presentationID: nil, intent: fallback.intent, handoffID: missingMetadata.id))
        folder.model.selectionGeneration &-= 1
        folder.model.currentReference = reference("b", peer: "other")
        precondition(!fallback.isCurrent(missingMetadata, scope: scope), "host mismatch rejects a same-ID selection")
        precondition(!fallback.show(session: folder, key: folderKey, reference: b, owner: UUID(),
            folderName: "", hostName: "", presentationID: nil, intent: fallback.intent, handoffID: missingMetadata.id))
        folder.model.currentReference = b
        folder.model = ChatModel()
        precondition(!fallback.isCurrent(missingMetadata, scope: scope), "model replacement rejects an old delivery")
        precondition(!fallback.show(session: folder, key: folderKey, reference: b, owner: UUID(),
            folderName: "", hostName: "", presentationID: nil, intent: fallback.intent, handoffID: missingMetadata.id))
        fallback.navigate()
        precondition(folder.canDiscard)

        // Real orchestration advances folder load, empty selection, exact opening.
        let opening = ClientChatSession(), openingHandoff = ClientChatLayoutHandoff()
        opening.model.currentReference = reference("b", peer: "other")
        precondition(!openingHandoff.show(session: opening, key: bKey, reference: b, owner: UUID(),
            folderName: "P", hostName: "Mac", presentationID: nil, intent: 0, handoffID: nil))
        precondition(opening.canDiscard, "invalid initial provenance acquires no lease")
        opening.model.currentReference = nil
        precondition(openingHandoff.show(session: opening, key: bKey, reference: b, owner: UUID(),
            folderName: "P", hostName: "Mac", presentationID: nil, intent: 0, handoffID: nil))
        let empty = openingHandoff.begin(route: route)!
        opening.model.selected = ChatConversation(id: "b")
        opening.model.currentReference = b
        opening.model.selectionGeneration = 1
        opening.model.selected = nil
        opening.model.currentReference = nil
        precondition(openingHandoff.isCurrent(empty, scope: scope))
        opening.model.selectionGeneration = 2
        precondition(openingHandoff.isCurrent(empty, scope: scope))
        opening.model.selected = ChatConversation(id: "b")
        opening.model.currentReference = b
        opening.model.selectionGeneration = 3
        precondition(openingHandoff.isCurrent(empty, scope: scope))
        opening.model.selected = ChatConversation(id: "other")
        precondition(!openingHandoff.isCurrent(empty, scope: scope))
        let staleIntent = openingHandoff.intent
        openingHandoff.navigate()
        precondition(!openingHandoff.show(session: opening, key: bKey, reference: b, owner: UUID(),
            folderName: "P", hostName: "Mac", presentationID: nil, intent: staleIntent, handoffID: nil))
        print("Chat handoff: exact reader, limit1 eviction, teardown order,30 folds, stale acknowledgement, Latest, Back, fallback, scope/model/generation and initial opening passed")
    }
}
