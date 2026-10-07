// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientChatSession.swift Singleflight.swift ChatDraftTransition.swift WorkReference.swift.
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
        selections += 1
        await onSelect?()
        selected = chat
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
struct ClientChatSessionTests {
    @MainActor
    static func main() async {
        let sessions = ClientChatSessions(limit: 2)
        let chat = sessions.session(peer: "mac", workspace: "project")
        chat.opened = ChatConversation(id: "conversation")
        chat.model.draft = "Keep writing through a fold"
        chat.model.attachments = ["screenshot"]
        await chat.load(workspaceID: "project", peer: "mac")
        for _ in 0..<30 {
            let remounted = sessions.session(peer: "mac", workspace: "project")
            precondition(remounted === chat)
            await remounted.load(workspaceID: "project", peer: "mac")
            precondition(remounted.opened?.id == "conversation")
            precondition(remounted.model.draft == "Keep writing through a fold")
            precondition(remounted.model.attachments == ["screenshot"])
        }
        precondition(chat.model.loads == 1, "remounts reuse the loaded model")
        await chat.load(workspaceID: "project", peer: "mac", refresh: true)
        precondition(chat.model.loads == 2, "explicit refresh still reads fresh data")
        precondition(sessions.session(peer: "other-mac", workspace: "project") !== chat)
        precondition(sessions.session(peer: "mac", workspace: "other-project") !== chat)
        precondition(sessions.session(peer: "mac", workspace: "project", conversation: "conversation") !== chat,
            "a notification reader cannot change the list's selected conversation")
        precondition(ClientChatSessions().session(peer: "mac", workspace: "project") !== chat,
            "another account/scene gets its own owners")

        let loading = ClientChatSession()
        let entered = Signal(), release = Signal(), arrived = Signal()
        loading.model.onLoad = { entered.signal(); await release.wait() }
        let oldLayout = Task { await loading.load(workspaceID: "p", peer: "m") }
        await entered.wait()
        oldLayout.cancel()
        let newLayout = Task {
            arrived.signal()
            await loading.load(workspaceID: "p", peer: "m")
        }
        await arrived.wait()
        await Task.yield()
        precondition(!loading.canDiscard, "pending reads survive layout cancellation")
        release.signal()
        await oldLayout.value
        await newLayout.value
        precondition(loading.model.loads == 1 && loading.loaded)

        for firstChat in [false, true] {
            let launching = ClientChatSession()
            if !firstChat { launching.model.mostRecent = ChatConversation(id: "recent") }
            let selecting = Signal(), finish = Signal(), successorArrived = Signal()
            launching.model.onSelect = { selecting.signal(); await finish.wait() }
            let previousLayout = Task { await launching.openMostRecent() }
            await selecting.wait()
            previousLayout.cancel()
            let successor = Task {
                successorArrived.signal()
                await launching.openMostRecent()
            }
            await successorArrived.wait()
            await Task.yield()
            precondition(launching.opened == nil && !launching.canDiscard)
            finish.signal()
            await previousLayout.value
            await successor.value
            precondition(launching.opened?.id == (firstChat ? "created" : "recent"))
            precondition(launching.model.selections == 1)
            precondition(launching.model.creates == (firstChat ? 1 : 0))
            launching.opened = nil
            launching.model.onSelect = nil
            await launching.openMostRecent()
            precondition(launching.opened != nil, "a fresh launcher visit still opens a conversation")
        }

        let retry = ClientChatSession()
        retry.model.failure = "temporary connection failure"
        await retry.load(workspaceID: "p", peer: "m")
        precondition(retry.loaded && retry.model.error != nil)
        retry.model.failure = nil
        await retry.load(workspaceID: "p", peer: "m")
        precondition(retry.model.loads == 2 && retry.model.error == nil,
            "a failed read is attempted again on remount and yesterday's error is cleared")

        let bounded = ClientChatSessions(limit: 1)
        let visible = bounded.session(peer: "m", workspace: "visible")
        let owner = UUID()
        visible.appear(owner)
        visible.appear(owner)
        _ = bounded.session(peer: "m", workspace: "next")
        precondition(bounded.session(peer: "m", workspace: "visible") === visible,
            "an on-screen idle reader remains owned")
        visible.disappear(owner)
        precondition(visible.model.saves == 1 && visible.canDiscard)
        _ = bounded.session(peer: "m", workspace: "last")
        precondition(bounded.session(peer: "m", workspace: "visible") !== visible,
            "inactive clean readers are evicted")
        for protect in 0..<9 {
            let store = ClientChatSessions(limit: 1)
            let protected = store.session(peer: "m", workspace: "protected")
            switch protect {
            case 0: protected.model.busy = true
            case 1: protected.model.sending = true
            case 2: protected.model.draft = "unsent"
            case 3: protected.model.attachments = ["file"]
            case 4: protected.model.stagingAttachments = 1
            case 5: protected.model.pendingQueue = ["queued"]
            case 6: protected.model.isCreating = true
            case 7: protected.model.openingConversation = true
            default: protected.model.unconfirmedSend = "pending receipt"
            }
            _ = store.session(peer: "m", workspace: "new")
            precondition(store.session(peer: "m", workspace: "protected") === protected,
                "active work and pending writing must not be evicted")
        }
        let mutations = ClientChatSessions()
        let folderReader = mutations.session(peer: "mac", workspace: "p")
        let exactReader = mutations.session(peer: "mac", workspace: "p", conversation: "a")
        let otherHost = mutations.session(peer: "other", workspace: "p", conversation: "a")
        for reader in [folderReader, exactReader, otherHost] {
            reader.opened = ChatConversation(id: "a")
            reader.retainedThread = reader.opened
            reader.model.selected = reader.opened
            reader.model.busy = true
            reader.model.draft = "Unsent words"
            reader.model.attachments = ["attachment"]
            reader.model.unconfirmedSend = "receipt"
        }
        let renamed = ChatConversation(id: "a", title: "New title")
        mutations.renamed(renamed, peer: "mac", workspace: "p")
        precondition(exactReader.opened == renamed && exactReader.model.selected == renamed)
        precondition(otherHost.opened?.title == "")
        await mutations.removed("a", peer: "mac", workspace: "p")
        precondition(folderReader.opened == nil && exactReader.retainedThread == nil && exactReader.model.selected == nil)
        precondition(exactReader.model.draft.isEmpty && exactReader.model.attachments.isEmpty && exactReader.model.unconfirmedSend == nil)
        precondition(exactReader.canDiscard && otherHost.opened != nil && !otherHost.canDiscard)

        let invalidated = ClientChatSession()
        let started = Signal(), finish = Signal()
        invalidated.model.onLoad = { started.signal(); await finish.wait() }
        let oldRead = Task { await invalidated.load(workspaceID: "p", peer: "m") }
        await started.wait()
        invalidated.invalidate()
        finish.signal()
        await oldRead.value
        invalidated.model.onLoad = nil
        await invalidated.load(workspaceID: "p", peer: "m")
        precondition(invalidated.model.loads == 2, "an invalidated in-flight read cannot mark the session reusable")
        print("ClientChatSessionTests passed: 30 remounts, cancellation, refresh, mutation, isolation and eviction.")
    }
}
