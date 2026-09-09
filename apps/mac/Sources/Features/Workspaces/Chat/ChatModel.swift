// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

@MainActor @Observable
final class ChatModel {
    private struct LaunchChoice: Codable {
        var backend: String
        var model: String?
        var effort: String?
        var mode: String
        var autonomy: String
        /// The persona the last conversation ended up with. Three states, and
        /// they are all different: absent means nothing has been recorded yet
        /// and the workspace default applies, empty means the person chose no
        /// persona, and an id means that one.
        var personaID: String?
    }

    private static let launchChoiceKey = "chat.lastLaunchChoice.v1"
    var chats: [ChatConversation] = []
    var selected: ChatConversation?
    var events: [ChatTimelineEvent] = []
    /// A prompt that has been sent and is not in `events` yet.
    ///
    /// The composer clears on Send. Without this the bubble is missing
    /// until the host answers, and a lazy stack can also skip that first
    /// landing until the next layout.
    private(set) var outgoing: [ChatDisplayItem] = []
    var approvals: [ChatApproval] = []
    /// What this conversation says to its agent ahead of the person's
    /// words. Read so the inspector can show it rather than describe it.
    var instructions: ChatInstructions?
    var offset: UInt64 = 0
    /// Asks the host for the page before the oldest one held. Nil once the
    /// beginning of the archive is on screen.
    private(set) var earlierCursor: String?
    /// Whether there is anything before what is held.
    private(set) var hasEarlier = false
    /// An older page is on its way, and the transcript should say so. Quiet
    /// backfill while a conversation opens does not set this: nobody is
    /// waiting at the top of a screen that has not been drawn yet.
    private(set) var loadingEarlier = false
    /// An older page is on its way at all.
    ///
    /// Separate from what the transcript shows, and the reason is that two
    /// loads on one cursor is how a stale cursor gets written back over a
    /// fresh one. Everything that fetches sets this.
    private var earlierInFlight = false
    /// Whether the person has actually paged back in this sitting. Until they
    /// have, saying "start of chat" would be announcing the obvious about a
    /// short conversation.
    private(set) var reachedStart = false
    /// What the whole conversation has spent, as counted by the host over the
    /// whole archive. Nil on a host that predates paging, and then the meter
    /// folds what is held, which on that host is everything.
    private(set) var conversationUsage: ChatUsageTotals?
    /// Where the host's count stopped. Usage written after this is added on
    /// top of it, so a turn taken while the conversation is open moves the
    /// meter without asking the host to read the archive again.
    private var usageThrough: UInt64 = 0
    /// This host predates `chat.eventPage`, so the timeline is read whole the
    /// way it always was. Latched per model, not per call: a host does not
    /// grow the method while a conversation is open.
    private var pagingUnavailable = false
    var attachments: [ChatAttachment] = []
    /// Downsampled JPEG for the composer strip, keyed by attachment id.
    var attachmentPreviews: [String: Data] = [:]
    /// Agent-returned file bytes, loaded lazily from the chat's owning host.
    /// The transcript only persists descriptors, so remote files work exactly
    /// like local ones without exposing a host filesystem path to SwiftUI.
    var responseAttachmentData: [String: Data] = [:]
    var backends: [ChatBackend] = []
    var personas: [ChatPersona] = []
    /// New conversations inherit this persona unless the person picks none.
    var defaultPersonaID: String?
    var isLoading = false
    /// The selected conversation's first page is still on its way.
    ///
    /// Separate from `isLoading`, which is about the folder's list. A chat
    /// that has been picked but not yet read back has no rows, and an empty
    /// transcript and an unread one look identical while meaning opposite
    /// things.
    private(set) var openingConversation = false
    var error: String?
    /// The folder id RootView knows, which is `remote:<peer>:<id>` for a
    /// workspace on another machine. Host methods use `workspaceID` instead.
    private(set) var folderID: String?
    /// The workspace id the owning host stores. Local, even for a remote folder.
    private(set) var workspaceID: String?
    /// Set when this model is talking to a peer over the tunnel.
    private(set) var peer: String?
    /// Async bridge calls may finish after navigation. Only the generation
    /// that started them may mutate the currently displayed workspace/chat.
    private var loadGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    /// Conversation a notification asked to open, consumed by the next load.
    private var pendingRevealID: String?
    /// The folder that reveal was asked for, so a load of a different one
    /// cannot answer for it. See the not-found branch in `load`.
    private var pendingRevealFolderID: String?
    // Old unscoped v1 ids cannot prove which account owned them. Leave them
    // untouched rather than silently migrating them into the next account.
    private var continuityScope: WorkReference.Scope?

    private func continuityOwner(folderID: String) -> (scope: WorkReference.Scope, host: String, workspace: String)? {
        guard let scope = continuityScope, scope == WorkSessionContext.shared.scope else { return nil }
        let route = WorkDestinationResolver.route(folderID: folderID,
            explicitPeer: folderID == self.folderID ? peer : nil)
        guard let host = route.peer ?? WorkSessionContext.shared.localHostIdentity else { return nil }
        return (scope, host, route.workspaceID)
    }

    private func rememberedChat(in folderID: String) -> String? {
        guard let owner = continuityOwner(folderID: folderID) else { return nil }
        return WorkContinuityStore.shared.lastConversation(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)?.itemID
    }

    private func rememberLastSelected(chatID: String, folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        WorkContinuityStore.shared.remember(WorkReference(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace,
            kind: .conversation, itemID: chatID))
    }

    private func forgetLastSelected(folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        WorkContinuityStore.shared.forget(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)
    }

    /// A deleted conversation takes its unsent words with it. There is nothing
    /// left to send them to.
    private func forgetDraft(chatID: String, folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        if draftConversationID == chatID {
            draftReference = nil
            draftConversationID = nil
        }
        ChatDraftStore.shared.clear(for: WorkReference(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace,
            kind: .conversation, itemID: chatID))
    }

    // MARK: - Unsent words

    /// What is in the composer.
    ///
    /// It lives here rather than in the view because it belongs to the
    /// conversation, not to the pane it was typed in. Switching conversations
    /// swaps it, leaving the folder keeps it, and it is on disk within a
    /// third of a second of the last keystroke.
    var draft = "" {
        didSet {
            guard !restoringDraft, draft != oldValue else { return }
            scheduleDraftSave()
        }
    }
    /// The conversation the words in `draft` belong to. Saves use this rather
    /// than recomputing a reference, so a save that lands after the selection
    /// moved still writes to the conversation the words were typed in.
    private var draftReference: WorkReference?
    /// The conversation the composer's words were typed into, known even
    /// before the account and machine identity that key them have arrived.
    private var draftConversationID: String?
    private var draftSaveTask: Task<Void, Never>?
    private var restoringDraft = false
    /// Long enough that a save is not queued per keystroke, short enough that
    /// nothing meaningful is lost to a crash.
    private static let draftSaveDelay = Duration.milliseconds(300)

    /// The last save did not reach the disk, so the composer is the only copy.
    var draftSaveFailed: Bool { ChatDraftStore.shared.saveFailed }

    /// Conversations in this folder with words waiting in them, so a list can
    /// mark them.
    func conversationsWithDrafts(in folderID: String) -> Set<String> {
        guard let owner = continuityOwner(folderID: folderID) else { return [] }
        return ChatDraftStore.shared.conversationsWithDrafts(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: ChatModel.draftSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    /// Write the composer out now: leaving the screen, going to the
    /// background, or handing the words to a send.
    func saveDraftNow() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard let reference = draftReference else { return }
        ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference)
    }

    /// Try the write again. The words never left the composer, so this is a
    /// retry of the save and not a resend of anything.
    func retryDraftSave() {
        ChatDraftStore.shared.retryFailedSave()
        saveDraftNow()
    }

    /// Point the composer at another conversation: the words on screen go to
    /// the one being left, and the one being opened brings its own back.
    private func loadDraft(for id: String?, scope: WorkReference.Scope?,
                           hostIdentity: String?, workspaceID: String?) {
        saveDraftNow()
        var reference: WorkReference?
        if let id, let scope, let hostIdentity, let workspaceID, !hostIdentity.isEmpty,
           !workspaceID.isEmpty {
            reference = WorkReference(scope: scope, hostIdentity: hostIdentity,
                workspaceID: workspaceID, kind: .conversation, itemID: id)
        }
        let transition = ChatDraftTransition.resolve(incoming: id, reference: reference,
            current: draftConversationID, currentReference: draftReference)
        draftConversationID = id
        draftReference = reference
        switch transition {
        case let .adopt(reference):
            draftReference = reference
            saveDraftNow()
        case .keep:
            break
        case let .swap(reference):
            setDraft("")
            guard let reference, let stored = ChatDraftStore.shared.draft(for: reference) else {
                return
            }
            setDraft(stored.text)
            if !stored.attachments.isEmpty, attachments.isEmpty {
                attachments = stored.attachments
            }
        }
    }

    private func loadDraft(for id: String?) {
        guard let id, let folderID, let owner = continuityOwner(folderID: folderID) else {
            loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            return
        }
        loadDraft(for: id, scope: owner.scope, hostIdentity: owner.host,
                  workspaceID: owner.workspace)
    }

    /// Clear the composer without persisting the change: for restoring stored
    /// words, and for a send that has not been answered yet.
    private func setDraft(_ text: String) {
        restoringDraft = true
        draft = text
        restoringDraft = false
    }

    /// Clear the composer but keep the stored copy until the send resolves.
    /// Nothing is lost if the app stops between the two.
    func holdDraftForSending() {
        saveDraftNow()
        setDraft("")
    }

    /// The host took the words, or they moved to the queue.
    func clearDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        setDraft("")
        if let reference = draftReference { ChatDraftStore.shared.clear(for: reference) }
    }

    /// The send did not happen. Put the words back where they were typed.
    func returnDraft(_ text: String) {
        guard draft.isEmpty else { return }
        setDraft(text)
    }

    /// Conversation lists read earlier this session, keyed by the folder id
    /// the sidebar knows (`remote:<peer>:<id>` for a folder on another
    /// machine). The model holds one folder's live list, while the cache lets
    /// the sidebar keep every opened folder's chats on screen, so opening a
    /// chat in one project does not collapse the one just left in another.
    /// Small records only, never transcripts. Refreshed on every open, so a
    /// stale entry lasts until its folder is opened again.
    private var chatListCache: [String: [ChatConversation]] = [:]
    private static let chatListCacheCap = 30

    /// The conversations to draw under this folder in the sidebar. The live
    /// list for the folder on screen, otherwise what its last load read, or
    /// nothing when the folder has not been opened in this session.
    func sidebarChats(in folderID: String) -> [ChatConversation] {
        guard continuityScope == WorkSessionContext.shared.scope else { return [] }
        if self.folderID == folderID { return chats }
        return chatListCache[folderID] ?? []
    }

    private func storeChatListCache(_ list: [ChatConversation], folderID: String) {
        chatListCache[folderID] = list
        if chatListCache.count > Self.chatListCacheCap,
           let drop = chatListCache.keys.first(where: { $0 != folderID }) {
            chatListCache.removeValue(forKey: drop)
        }
    }
    private var attachmentCacheGeneration: UInt64 = 0
    private var attemptedResponseAttachments: Set<String> = []
    private(set) var loadingResponseAttachments: Set<String> = []
    private(set) var responseAttachmentErrors: [String: String] = [:]

    /// Whether this model has answered for the folder on screen.
    ///
    /// Nothing may draw "no conversations here" before this is true: the
    /// pane would promise an empty folder and then contradict itself.
    func isReady(for workspaceID: String) -> Bool {
        folderID == workspaceID && !isLoading
    }

    func count(in workspaceID: String) -> Int {
        guard folderID == workspaceID || self.workspaceID == workspaceID else { return 0 }
        return chats.count
    }

    func load(workspaceID: String, peer: String? = nil, selectFirst: Bool = true) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let route = Bridge.chatRoute(workspaceID: workspaceID, peer: peer)
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        let scope = WorkSessionContext.shared.scope
        if route.peer == nil {
            await WorkSessionContext.shared.resolveLocalHostIdentity()
            guard generation == loadGeneration, scope == WorkSessionContext.shared.scope else { return }
        }
        let rememberedID: String?
        if let scope, let host = route.peer ?? WorkSessionContext.shared.localHostIdentity {
            rememberedID = WorkContinuityStore.shared.lastConversation(scope: scope,
                hostIdentity: host, workspaceID: route.workspaceID)?.itemID
        } else {
            rememberedID = nil
        }
        if continuityScope != scope {
            // A different account, rather than the first one arriving: these
            // words belong to the account being left, where they were kept.
            if let previous = continuityScope, let scope, previous != scope {
                loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            }
            chatListCache = [:]
            chats = []
            selected = nil
            folderID = nil
            continuityScope = scope
        }
        let draftHost = route.peer ?? WorkSessionContext.shared.localHostIdentity
        if folderID != workspaceID || self.workspaceID != route.workspaceID || self.peer != route.peer {
            // The folder is changing. Remember which conversation was open
            // before the clear below drops it, or coming back can only ever
            // find the first row.
            if let selected, let old = folderID {
                rememberLastSelected(chatID: selected.id, folderID: old)
            }
            if let old = folderID, !chats.isEmpty {
                storeChatListCache(chats, folderID: old)
            }
            if selectFirst, let cached = chatListCache[workspaceID] {
                // Opened before. Show its remembered conversation at once,
                // from the cache, while the refresh below re-reads the list.
                // Clicking the Chat row then opens the last chat rather than
                // an empty loading state, and the transcript fetch runs once,
                // after the list confirms what is still there.
                if let pending = pendingRevealID,
                   (pendingRevealFolderID == nil || pendingRevealFolderID == workspaceID),
                   let found = cached.first(where: { $0.id == pending }) {
                    selected = found
                } else if let remembered = rememberedID,
                          let found = cached.first(where: { $0.id == remembered }) {
                    selected = found
                } else {
                    selected = cached.first
                }
                chats = cached
                events = []
                outgoing = []
                outgoingWatermark = [:]
                approvals = []
                instructions = nil
                attachments = []
                attachmentPreviews = [:]
                responseAttachmentData = [:]
                attemptedResponseAttachments = []
                loadingResponseAttachments = []
                responseAttachmentErrors = [:]
                forgetWindow()
                loadQueue(for: selected?.id)
                loadDraft(for: selected?.id, scope: scope, hostIdentity: draftHost,
                          workspaceID: route.workspaceID)
                openingConversation = selected != nil
            } else {
                chats = []
                selected = nil
                events = []
                outgoing = []
                outgoingWatermark = [:]
                approvals = []
                forgetWindow()
                loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            }
            selectionGeneration &+= 1
        }
        folderID = workspaceID
        self.workspaceID = route.workspaceID
        self.peer = route.peer
        do {
            async let loadedBackends = Bridge.chatBackends(peer: route.peer)
            async let loadedPersonas = Bridge.chatPersonas(workspaceID: route.workspaceID, peer: route.peer)
            async let loadedChats = Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            let loaded = try await (loadedBackends, loadedPersonas, loadedChats)
            guard generation == loadGeneration, scope == WorkSessionContext.shared.scope else { return }
            backends = loaded.0
            personas = loaded.1.personas
            // The host says "" for a workspace that has chosen no persona.
            // Nil here means the same thing, and every reader already handles
            // it, so the empty string never gets past this line.
            defaultPersonaID = loaded.1.defaultId.isEmpty ? nil : loaded.1.defaultId
            chats = Self.uniqued(loaded.2)
            storeChatListCache(chats, folderID: workspaceID)
            if let pending = pendingRevealID {
                if let found = chats.first(where: { $0.id == pending }) {
                    pendingRevealID = nil
                    pendingRevealFolderID = nil
                    if selected?.id == found.id {
                        if found != selected { self.selected = found }
                        await refreshOpen(id: found.id)
                    } else {
                        await select(found)
                    }
                } else {
                    // The host has just answered with the whole list and the
                    // conversation a notification named is not in it, so it
                    // was deleted and no later load will find it either.
                    // Clearing the reveal is the point: it used to survive
                    // this branch and re-run on every load of the folder,
                    // blanking the pane for an id that is never coming back.
                    //
                    // Only this folder may say so. A reveal armed for another
                    // one is waiting for its own load, and answering for it
                    // here would drop the tap on the floor.
                    if pendingRevealFolderID == nil || pendingRevealFolderID == workspaceID {
                        pendingRevealID = nil
                        pendingRevealFolderID = nil
                    }
                    if let selected, let fresh = chats.first(where: { $0.id == selected.id }) {
                        if fresh != selected { self.selected = fresh }
                        await refreshOpen(id: fresh.id)
                    } else if selectFirst {
                        await select(chats.first)
                    } else {
                        await select(nil)
                    }
                }
            } else if let selected, let fresh = chats.first(where: { $0.id == selected.id }) {
                // This conversation is already open. Re-selecting it would
                // empty the transcript and read it back, which is a blank
                // pane, a persona where the last turn was, and a lost scroll
                // position every time somebody leaves this screen and comes
                // back to it. Take the fresh record and keep the rows.
                if fresh != selected { self.selected = fresh }
                await refreshOpen(id: fresh.id)
            } else if selectFirst {
                // No reveal named one and the old selection is gone with the
                // folder change. Reopen this folder's own conversation when
                // it is still here; the first row only when it is not.
                if let remembered = rememberedID,
                   let found = chats.first(where: { $0.id == remembered }) {
                    await select(found)
                } else {
                    await select(chats.first)
                }
            } else {
                await select(nil)
            }
        } catch {
            if generation == loadGeneration {
                self.error = error.localizedDescription
                // A primed folder otherwise keeps its opening state with
                // nothing coming to clear it.
                openingConversation = false
            }
        }
    }

    private static func uniqued(_ chats: [ChatConversation]) -> [ChatConversation] {
        var seen = Set<String>()
        return chats.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// Open this conversation once its folder is loaded.
    ///
    /// A notification tap names a thread this model may not have read yet.
    /// Stash the id so `load` selects it instead of the first row. Callers
    /// that already hold the folder also select immediately.
    /// Open this conversation on the next load that can see it.
    ///
    /// `folderID` is the folder it lives in, when the caller knows: a load of
    /// any other folder then leaves the reveal alone rather than deciding on
    /// a list that was never going to contain it.
    func reveal(id: String, in folderID: String? = nil) {
        guard !id.isEmpty else { return }
        pendingRevealID = id
        pendingRevealFolderID = folderID
    }

    func select(_ chat: ChatConversation?) async {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selected = chat
        if let chat, let folderID {
            rememberLastSelected(chatID: chat.id, folderID: folderID)
        }
        attachments = []
        attachmentPreviews = [:]
        responseAttachmentData = [:]
        attemptedResponseAttachments = []
        loadingResponseAttachments = []
        responseAttachmentErrors = [:]
        approvals = []
        instructions = nil
        events = []
        outgoing = []
        outgoingWatermark = [:]
        forgetWindow()
        loadQueue(for: chat?.id)
        loadDraft(for: chat?.id)
        #if os(macOS)
        if let chat { RunNotifications.shared.chatAttentionHandled(id: chat.id) }
        #endif
        guard let chat else {
            openingConversation = false
            return
        }
        openingConversation = true
        defer {
            if selectionGeneration == generation { openingConversation = false }
        }
        await openEvents(id: chat.id, generation: generation)
        await loadApprovals(id: chat.id, generation: generation)
        await loadInstructions(id: chat.id, generation: generation)
        #if !os(macOS)
        if !Task.isCancelled, selectionMatches(id: chat.id, generation: generation) {
            ClientChatReadState.shared.markRead(peer: peer, chat: selected ?? chat)
        }
        #endif
        if selectionMatches(id: chat.id, generation: generation) {
            await drainQueue()
        }
    }

    /// Bring an already open conversation up to date without emptying it.
    ///
    /// The counterpart to `select`, for the case where the conversation on
    /// screen is the one being asked for. Everything here adds to what is
    /// held: no reset, so no row that is already drawn is drawn again.
    private func refreshOpen(id: String) async {
        let generation = selectionGeneration
        if events.isEmpty {
            // No rows held, so this is an opening whatever it is called from,
            // and the transcript has to know: revealing an empty transcript
            // and then filling it is the build-up the wireframe exists to
            // cover.
            openingConversation = true
            defer {
                if selectionGeneration == generation { openingConversation = false }
            }
            await openEvents(id: id, generation: generation)
        } else {
            await loadEvents(id: id, reset: false, generation: generation)
        }
        guard selectionMatches(id: id, generation: generation) else { return }
        await loadApprovals(id: id, generation: generation)
        guard selectionMatches(id: id, generation: generation) else { return }
        if instructions == nil {
            await loadInstructions(id: id, generation: generation)
        }
        guard selectionMatches(id: id, generation: generation) else { return }
        await drainQueue()
    }

    /// Reopen the conversation on its newest page, dropping the window that
    /// paging back has grown.
    ///
    /// Every scroll to something far from the viewport costs the lazy stack a
    /// walk over each item in between, so a window grown to thousands of rows
    /// makes coming back to the latest turn expensive in a way no amount of
    /// scrolling can fix. Returning to the end is the one moment that window
    /// can be dropped: the newest page is exactly what is being asked for,
    /// and what is before it is a page away again.
    func reopenAtLatest() async {
        guard let selected else { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        events = []
        outgoing = []
        outgoingWatermark = [:]
        forgetWindow()
        openingConversation = true
        defer {
            if selectionGeneration == generation { openingConversation = false }
        }
        await openEvents(id: selected.id, generation: generation)
    }

    func create() async {
        guard let workspaceID else { return }
        let context = loadGeneration
        let targetPeer = peer
        do {
            if backends.isEmpty {
                let loaded = try await Bridge.chatBackends(peer: targetPeer)
                guard context == loadGeneration else { return }
                backends = loaded
            }
            let saved = lastLaunchChoice
            let chosen = backends.first { $0.id == saved?.backend }
                ?? backends.first { $0.id == "codex" }
                ?? backends.first(where: { $0.id != "sh" })
                ?? backends.first
            let model = chosen?.models.contains(saved?.model ?? "") == true ? saved?.model : nil
            let effort = chosen?.efforts.contains(saved?.effort ?? "") == true ? saved?.effort : nil
            let chat = try await Bridge.createChat(
                workspaceID: workspaceID,
                backend: chosen?.id ?? "claude",
                // Execute, not plan, for a first chat on a machine. The
                // saved choice wins as soon as there is one, so this is only
                // ever the very first conversation somebody opens, and
                // planning at them is a turn that does nothing they asked
                // for. Autonomy stays standard: the agent acts, and a tool
                // that needs permission still stops and asks.
                mode: saved?.mode ?? "execute",
                autonomy: chosen?.gateTier == "bypassOnly"
                    ? "bypass"
                    : (saved?.autonomy ?? "standard"),
                model: model,
                effort: effort,
                personaID: rememberedPersonaID(saved),
                peer: targetPeer
            )
            guard context == loadGeneration else { return }
            chats.insert(chat, at: 0)
            if let folderID { storeChatListCache(chats, folderID: folderID) }
            await select(chat)
        } catch {
            if context == loadGeneration { self.error = error.localizedDescription }
        }
    }

    /// Take the backend list again when the one in hand looks like a daemon
    /// that had not finished probing.
    ///
    /// The host answers immediately and fills its model lists on a background
    /// thread, so the first request after it starts is served from curated
    /// fallbacks. A client that asks once, at launch, and keeps the answer
    /// forever is holding that half-filled list for the life of the window,
    /// which is how a Codex chat ended up with no model picker on a machine
    /// whose host could list six models a second later.
    ///
    /// Unforced: this is the ordinary cached read, arriving late enough to be
    /// the real one. Refresh in the picker is the other call, for a list that
    /// is complete but out of date.
    func refillBackendsIfIncomplete() async {
        guard let chosen = backends.first(where: { $0.id == selected?.backend }) else { return }
        guard chosen.models.isEmpty, chosen.id != "sh" else { return }
        let context = loadGeneration
        guard let loaded = try? await Bridge.chatBackends(peer: peer) else { return }
        guard context == loadGeneration else { return }
        backends = loaded
    }

    /// Ask this conversation's host to read the agent CLIs' model lists again.
    ///
    /// The host caches them for ten minutes, which is right for a picker that
    /// opens on every screen and wrong the moment somebody adds an API key to
    /// a CLI and comes straight here looking for the models it just gained.
    /// Errors are swallowed on purpose: the list on screen is still the list,
    /// and an alert over a picker that already works would be worse than a
    /// button that changed nothing.
    func reloadBackends() async {
        let context = loadGeneration
        guard let loaded = try? await Bridge.chatBackends(peer: peer, refresh: true) else { return }
        guard context == loadGeneration else { return }
        backends = loaded
    }

    func update(
        title: String? = nil,
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        mode: String? = nil,
        autonomy: String? = nil,
        personaID: String? = nil,
        systemPrompt: String? = nil,
        allowedTools: [String]? = nil,
        allowedShellPrefixes: [String]? = nil
    ) async {
        guard let selected else { return }
        let generation = selectionGeneration
        do {
            let updated = try await Bridge.updateChat(
                id: selected.id,
                title: title,
                backend: backend,
                model: model,
                effort: effort,
                mode: mode,
                autonomy: autonomy,
                personaID: personaID,
                systemPrompt: systemPrompt,
                allowedTools: allowedTools,
                allowedShellPrefixes: allowedShellPrefixes,
                peer: peer
            )
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            replace(updated)
            // The backend decides whether the rules travel on a flag or ahead
            // of the turn, and the brief is half of what they say. Either
            // moving means the shown text is stale.
            if backend != nil || systemPrompt != nil || personaID != nil {
                await loadInstructions(id: selected.id, generation: generation)
            }
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    /// Give this conversation a voice, and change nothing else.
    ///
    /// A persona no longer picks the agent, the model, the mode or the
    /// autonomy: those belong to the conversation and the person adjusts them
    /// there. That is what lets one persona be used with any agent, and what
    /// lets it survive a chat being handed from one to another.
    func applyPersona(_ persona: ChatPersona?) async {
        guard let persona else {
            await update(personaID: "", systemPrompt: "")
            return
        }
        await update(personaID: persona.id, systemPrompt: persona.systemPrompt)
    }

    /// Ask an agent for a starting point, from a sentence about what the
    /// persona should be good at. Returns a draft for a form, never a save.
    func draftPersona(brief: String, backend: String, name: String? = nil) async -> ChatPersonaDraft? {
        do {
            return try await Bridge.draftChatPersona(
                brief: brief,
                backend: backend,
                name: name,
                peer: peer
            )
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func remove(_ chat: ChatConversation) async {
        await remove(chat, in: folderID)
    }

    /// Delete one conversation shown in the sidebar.
    ///
    /// A row under another folder cannot use the live peer, which is the
    /// folder on screen and not the conversation's host. Routing by folder id
    /// deletes from the owning host and drops the row from the cache, leaving
    /// the open transcript alone.
    func remove(_ chat: ChatConversation, in folderID: String?) async {
        let targetPeer = WorkDestinationResolver.deletionPeer(folderID: folderID, currentFolderID: self.folderID, currentPeer: peer)
        let context = loadGeneration
        do {
            try await Bridge.removeChat(id: chat.id, peer: targetPeer)
            guard context == loadGeneration else { return }
            if let folderID { forgetDraft(chatID: chat.id, folderID: folderID) }
            if let folderID, folderID != self.folderID {
                chatListCache[folderID]?.removeAll { $0.id == chat.id }
                if rememberedChat(in: folderID) == chat.id { forgetLastSelected(folderID: folderID) }
                if pendingRevealID == chat.id,
                   pendingRevealFolderID == nil || pendingRevealFolderID == folderID {
                    pendingRevealID = nil
                    pendingRevealFolderID = nil
                }
            } else {
                if let folderID, rememberedChat(in: folderID) == chat.id {
                    forgetLastSelected(folderID: folderID)
                }
                chats.removeAll { $0.id == chat.id }
                if let folderID { storeChatListCache(chats, folderID: folderID) }
                if selected?.id == chat.id {
                    await select(chats.first)
                }
            }
        } catch {
            if context == loadGeneration { self.error = error.localizedDescription }
        }
    }

    func removeAll(in folderID: String) async {
        let context = loadGeneration
        do {
            // `folderID` may encode a different remote peer than the chat
            // currently loaded in this model. Let the bridge route the folder
            // itself instead of borrowing the current conversation's peer.
            _ = try await Bridge.removeAllChats(workspaceID: folderID)
            guard context == loadGeneration else { return }
            storeChatListCache([], folderID: folderID)
            forgetLastSelected(folderID: folderID)
            if self.folderID == folderID || workspaceID == folderID {
                chats = []
                await select(nil)
            }
        } catch {
            if context == loadGeneration { self.error = error.localizedDescription }
        }
    }

    /// A send is in flight. Set synchronously on entry (the main actor runs
    /// one task at a time, so a second tap cannot slip between the check and
    /// the set) and cleared when the bridge answers. The composer disables
    /// Send on this; without it a double-tap re-sent the same attachments,
    /// which image-only sends made reachable.
    private(set) var sending = false
    /// Messages waiting for the open turn to finish. Kept per conversation so
    /// leaving the thread and coming back still has them.
    private(set) var queued: [ChatQueuedMessage] = []
    private var queuedConversationID: String?
    /// Send now is in flight. `drainQueue` must not pick the next waiting
    /// message while this one is still stopping the open turn.
    @ObservationIgnored private var sendingNow = false
    private static let queueCap = 20
    private static let queueKeyPrefix = "chat.queuedMessages.v1."

    /// Queue a message for when the current turn ends. The composer stays
    /// usable mid-turn: the host will not take a second send until this one
    /// finishes, so the words wait here.
    @discardableResult
    func enqueue(_ text: String, atFront: Bool = false) -> ChatQueuedMessage? {
        guard selected != nil else { return nil }
        if queued.count >= Self.queueCap {
            error = "Already \(Self.queueCap) messages waiting."
            return nil
        }
        let item = ChatQueuedMessage(
            id: UUID().uuidString,
            text: text,
            attachments: attachments
        )
        if atFront {
            queued.insert(item, at: 0)
        } else {
            queued.append(item)
        }
        attachments = []
        attachmentPreviews = [:]
        persistQueue()
        return item
    }

    func updateQueued(_ item: ChatQueuedMessage, text: String) {
        guard let index = queued.firstIndex(where: { $0.id == item.id }) else { return }
        queued[index].text = text
        persistQueue()
    }

    func removeQueued(_ item: ChatQueuedMessage) {
        queued.removeAll { $0.id == item.id }
        persistQueue()
    }

    /// Drag reorder from the pending sheet. The order is the send order,
    /// so it persists like every other queue change.
    func moveQueued(from offsets: IndexSet, to destination: Int) {
        queued.move(fromOffsets: offsets, toOffset: destination)
        persistQueue()
    }

    /// Stop the current turn and send this queued message as soon as the
    /// host will take it. Remaining queued items stay waiting.
    ///
    /// The item leaves the strip first, so Send now is visible as the turn
    /// stopping rather than as a no-op on the same waiting row. A stale
    /// tool row must not hold the send: the conversation's own running
    /// flag is what the host uses to accept the next prompt.
    func sendNow(_ item: ChatQueuedMessage) async {
        guard !sendingNow else { return }
        sendingNow = true
        defer { sendingNow = false }
        let targetID = selected?.id
        let generation = selectionGeneration
        let originalIndex = queued.firstIndex(where: { $0.id == item.id }) ?? 0
        removeQueued(item)
        if selected?.running == true {
            await stop()
            for _ in 0..<80 {
                if Task.isCancelled { break }
                guard selectionMatches(id: targetID ?? "", generation: generation) else { break }
                if selected?.running != true, !sending { break }
                await poll()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard let targetID else {
            queued.insert(item, at: min(originalIndex, queued.count))
            persistQueue()
            return
        }
        guard selectionMatches(id: targetID, generation: generation) else {
            Self.reappendToStoredQueue(item, at: originalIndex, conversationID: targetID)
            return
        }
        if sending || selected?.running == true {
            queued.insert(item, at: min(originalIndex, queued.count))
            persistQueue()
            return
        }
        let ok = await send(item.text, attachmentIDs: item.attachments.map(\.id))
        if !ok {
            // The selection may have moved during the send. Only touch the
            // live queue when it is still this conversation; otherwise write
            // back to the owning conversation's stored queue.
            if selectionMatches(id: targetID, generation: generation) {
                queued.insert(item, at: min(originalIndex, queued.count))
                persistQueue()
            } else {
                Self.reappendToStoredQueue(item, at: originalIndex, conversationID: targetID)
            }
        }
    }

    func drainQueue() async {
        guard !busy, !sending, !sendingNow, let item = queued.first else { return }
        guard let ownerID = selected?.id else { return }
        let generation = selectionGeneration
        let originalIndex = 0
        queued.removeFirst()
        persistQueue()
        let ok = await send(item.text, attachmentIDs: item.attachments.map(\.id))
        if !ok {
            if selectionMatches(id: ownerID, generation: generation) {
                queued.insert(item, at: min(originalIndex, queued.count))
                persistQueue()
            } else {
                Self.reappendToStoredQueue(item, at: originalIndex, conversationID: ownerID)
            }
        } else if selectionMatches(id: ownerID, generation: generation) {
            // A send that won the race with the turn ending left this item
            // waiting one extra turn. Chain while still idle and owned.
            await drainQueue()
        }
    }

    @discardableResult
    func send(_ text: String, attachmentIDs: [String]? = nil) async -> Bool {
        guard let selected, !sending else { return false }
        sending = true
        let staged = stageOutgoing(text)
        defer { sending = false }
        let generation = selectionGeneration
        let ids = attachmentIDs ?? attachments.map(\.id)
        do {
            let updated = try await Bridge.sendChat(
                id: selected.id,
                text: text,
                attachmentIDs: ids,
                peer: peer
            )
            guard selectionMatches(id: updated.id, generation: generation) else {
                dropOutgoing(staged)
                return false
            }
            replace(updated)
            let sent = Set(ids)
            attachments.removeAll { sent.contains($0.id) }
            for id in sent { attachmentPreviews.removeValue(forKey: id) }
            await loadEvents(id: updated.id, reset: false, generation: generation)
            return true
        } catch {
            dropOutgoing(staged)
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
            return false
        }
    }

    func attach(_ file: URL) async {
        guard let item = ChatInbox.item(from: file) else {
            error = "That file could not be read."
            return
        }
        await attach(item)
    }

    func attach(_ item: ChatInboxItem) async {
        guard let selected else { return }
        let generation = selectionGeneration
        if item.data.count > ChatInbox.maxBytes {
            error = "An attachment is limited to 12 MB."
            return
        }
        do {
            let attachment = try await Bridge.attachToChat(
                id: selected.id,
                name: item.name,
                data: item.data,
                mediaType: item.mediaType,
                peer: peer
            )
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            attachments.append(attachment)
            if let preview = ChatThumbnail.make(from: item.data) {
                attachmentPreviews[attachment.id] = preview
            }
            // A file staged for an unsent message is part of that draft.
            saveDraftNow()
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        attachmentPreviews.removeValue(forKey: attachment.id)
        saveDraftNow()
    }

    func stop() async {
        guard let selected else { return }
        let generation = selectionGeneration
        do {
            try await Bridge.stopChat(id: selected.id, peer: peer)
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
            return
        }
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        await loadEvents(id: selected.id, reset: false, generation: generation)
        await loadApprovals(id: selected.id, generation: generation)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        do {
            let latest = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            // Only when it actually moved. Observation notifies on the write,
            // not on the difference, and this runs four hundred milliseconds
            // at a time: an unconditional assignment redraws every open
            // transcript twice a second for nothing.
            if chats != latest {
                chats = latest
                if let folderID { storeChatListCache(chats, folderID: folderID) }
            }
            if let current = latest.first(where: { $0.id == selected.id }),
               current != self.selected {
                self.selected = current
            }
            settleNotifications()
        } catch {}
    }

    func resolve(_ approval: ChatApproval, choice: String) async {
        let generation = selectionGeneration
        do {
            _ = try await Bridge.resolveChatApproval(id: approval.id, choice: choice, peer: peer)
            guard selectionMatches(id: approval.conversationID, generation: generation) else { return }
            await loadApprovals(id: approval.conversationID, generation: generation)
            #if os(macOS)
            RunNotifications.shared.chatAttentionHandled(id: approval.conversationID)
            #endif
        } catch {
            if selectionMatches(id: approval.conversationID, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    func savePersona(_ persona: ChatPersona) async -> ChatPersona? {
        do {
            let saved = try await Bridge.saveChatPersona(
                persona,
                workspaceID: workspaceID,
                peer: peer
            )
            if let index = personas.firstIndex(where: { $0.id == saved.id }) {
                personas[index] = saved
            } else {
                personas.append(saved)
            }
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func removePersona(_ persona: ChatPersona) async {
        do {
            try await Bridge.removeChatPersona(id: persona.id, peer: peer)
            personas.removeAll { $0.id == persona.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Choose the persona new chats in this workspace inherit, or none.
    ///
    /// Nil is a real choice and it persists. Before, "no persona" lasted one
    /// conversation: the host read a workspace with no default as one nobody
    /// had set up yet and made a fresh persona for the next chat.
    func setDefaultPersona(_ persona: ChatPersona?) async {
        guard let workspaceID else { return }
        do {
            let saved = try await Bridge.setDefaultChatPersona(
                workspaceID: workspaceID,
                personaID: persona?.id ?? "",
                peer: peer
            )
            defaultPersonaID = saved?.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// An idle conversation can receive a turn from another device. Keep
    /// watching its event offset, then return to fast reads when work appears.
    var pollInterval: Duration {
        busy || hasPendingResponseAttachments ? .milliseconds(400) : .seconds(2)
    }

    func poll() async {
        guard !Task.isCancelled, !openingConversation, let selected else { return }
        let generation = selectionGeneration
        await loadEvents(id: selected.id, reset: false, generation: generation, quiet: true)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        await loadApprovals(id: selected.id, generation: generation)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        do {
            let latest = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            // A poll that found nothing new must not write anything back.
            // Same rule as the event chunk below: the write is what redraws
            // the transcript, and most polls of a running turn arrive with
            // an unchanged list.
            if chats != latest {
                chats = latest
                if let folderID { storeChatListCache(chats, folderID: folderID) }
            }
            if let current = latest.first(where: { $0.id == selected.id }),
               current != self.selected {
                self.selected = current
                #if !os(macOS)
                if !Task.isCancelled {
                    ClientChatReadState.shared.markRead(peer: peer, chat: current)
                }
                #endif
            }
            settleNotifications()
        } catch {}
    }

    var busy: Bool {
        selected?.running == true || hasRunningTool
    }

    var hasRunningTool: Bool {
        // Memoized via the same DisplayKey as displayItems itself: scanning
        // displayItems on every poll (400ms) and on every onChange was the
        // second per-frame cost after coalescing.
        hasRunningToolCache(for: displayKey) ?? computeHasRunningTool()
    }

    @ObservationIgnored private var hasRunningToolCacheKey: DisplayKey?
    @ObservationIgnored private var hasRunningToolCacheValue = false

    private func hasRunningToolCache(for key: DisplayKey?) -> Bool? {
        guard let key, key == hasRunningToolCacheKey else { return nil }
        return hasRunningToolCacheValue
    }

    private func computeHasRunningTool() -> Bool {
        let value = displayItems.contains { item in
            switch item.kind {
            case let .tool(state): return state.running
            case let .edit(state): return state.running
            default: return false
            }
        }
        hasRunningToolCacheKey = displayKey
        hasRunningToolCacheValue = value
        return value
    }

    var hasPendingResponseAttachments: Bool {
        !loadingResponseAttachments.isEmpty
    }

    /// The face of the conversation on screen.
    ///
    /// Its persona's, when it has one, so the same character follows a persona
    /// between chats. Otherwise the chat's own, derived from its id, because
    /// every conversation should have a face whether or not anybody has made a
    /// persona yet.
    var faceSeed: UInt64 {
        selected.map(faceSeed(for:)) ?? personaSeed(for: "chat")
    }

    /// The face for a chat that does not exist yet.
    ///
    /// The workspace's default persona, because that is the character the next
    /// conversation in this folder will actually have. An empty screen showing
    /// some other creature would be introducing somebody who never turns up.
    ///
    /// Falls back to the first persona there is, and then to a face derived
    /// from the workspace itself, so a folder whose personas have not loaded
    /// yet still has a character rather than a gap.
    var defaultFaceSeed: UInt64 {
        if let defaultPersonaID,
           let persona = personas.first(where: { $0.id == defaultPersonaID }) {
            return persona.seed
        }
        if let first = personas.first {
            return first.seed
        }
        return personaSeed(for: workspaceID ?? folderID ?? "chat")
    }

    /// The face a conversation carries when it is shown somewhere other than
    /// the open transcript, such as the workspace launcher.
    func faceSeed(for chat: ChatConversation) -> UInt64 {
        if let personaID = chat.personaID,
           let persona = personas.first(where: { $0.id == personaID }) {
            return persona.seed
        }
        return personaSeed(for: chat.id)
    }

    /// The conversation worth returning to, independent of list ordering.
    var mostRecent: ChatConversation? {
        chats.max { lhs, rhs in lhs.updatedAtMs < rhs.updatedAtMs }
    }

    /// True while a tool is actually running, as opposed to the agent thinking.
    var isRunningTool: Bool {
        displayItems.contains { item in
            switch item.kind {
            case let .tool(state): return state.running
            case let .edit(state): return state.running
            default: return false
            }
        }
    }

    func backend(for id: String) -> ChatBackend? {
        backends.first { $0.id == id }
    }

    /// What this conversation has spent.
    ///
    /// The host's figure where there is one, because it covers the whole
    /// archive and this model only holds a window of it. Folding what is
    /// resident would make the meter climb as somebody read backwards.
    var turnUsage: ChatUsageTotals? {
        // Read on every draw of the meter, which redraws on every poll.
        // Folding the whole window that often is what made a long running
        // chat re-scan thousands of records 2.5x a second.
        let key = UsageKey(
            epoch: eventsEpoch,
            count: events.count,
            firstSeq: events.first?.seq,
            lastSeq: events.last?.seq,
            through: usageThrough,
            hasBase: conversationUsage != nil
        )
        if key == turnUsageKey { return turnUsageCache }
        var totals = conversationUsage ?? .zero
        for timeline in events {
            guard let event = timeline.event, event.kind == "usage" else { continue }
            // With a host figure in hand, only what has been written since it
            // was counted. Without one, this host reads whole conversations,
            // so everything held is everything there is.
            if conversationUsage != nil, (timeline.seq ?? 0) < usageThrough { continue }
            totals.input += event.input ?? 0
            totals.output += event.output ?? 0
            totals.cacheRead += event.cacheRead ?? 0
            totals.cacheWrite += event.cacheWrite ?? 0
            totals.cost += event.costUsd ?? 0
        }
        let answer: ChatUsageTotals? = totals.isEmpty ? nil : totals
        turnUsageCache = answer
        turnUsageKey = key
        return answer
    }

    /// What a cached usage fold was folded from. Same window identity as the
    /// row cache, plus what the fold itself filters on.
    private struct UsageKey: Equatable {
        var epoch: UInt64
        var count: Int
        var firstSeq: UInt64?
        var lastSeq: UInt64?
        var through: UInt64
        var hasBase: Bool
    }

    @ObservationIgnored private var turnUsageCache: ChatUsageTotals?
    @ObservationIgnored private var turnUsageKey: UsageKey?

    var hasStarted: Bool {
        !events.isEmpty || selected?.resumeToken != nil
    }

    /// Consecutive text and thinking deltas become one block each, and a
    /// ToolEnd lands on the ToolStart it belongs to so the row can show
    /// running, duration and failure without a second line.
    ///
    /// Answered from the last result while the records behind it are the same
    /// ones. Every view of a conversation reads this several times per draw
    /// (the rows themselves, whether a tool is running, what the live seat is
    /// doing, which rows to measure), and folding a window of several hundred
    /// records into rows that many times per frame is what made a long chat
    /// impossible to scroll.
    var displayItems: [ChatDisplayItem] {
        // Reading `events` here is also what tells Observation that a view
        // depends on it, so the cheap path must still touch it.
        let key = DisplayKey(
            epoch: eventsEpoch,
            count: events.count,
            firstSeq: events.first?.seq,
            lastSeq: events.last?.seq,
            backend: selected?.backend
        )
        let pending = outgoing
        let coalesced: [ChatDisplayItem]
        if key == displayKey {
            coalesced = displayCache
        } else {
            displayCache = ChatDisplayItem.coalesce(events, defaultBackend: key.backend)
            displayKey = key
            coalesced = displayCache
        }
        if pending.isEmpty { return coalesced }
        return coalesced + pending
    }

    /// Parse the prose in the rows now, off the main thread.
    ///
    /// Called when a page of a conversation lands, never while one is
    /// streaming. A row that scrolls into view would otherwise parse its own
    /// markdown inside `init`, on the main thread, in the middle of a layout
    /// pass, which is a stall on exactly the frame a reader is scrolling back
    /// through history. A message that is still being written is a different
    /// string on every token and is not worth warming.
    func warmMarkdown() {
        MarkdownText.warm(displayItems.compactMap { item in
            switch item.kind {
            case let .user(text): text
            case let .assistant(text, _): text
            case let .thinking(text): text
            case let .failed(text): text
            case let .handoff(_, brief): brief
            default: nil
            }
        })
    }

    /// What the cached rows were folded from. Cheap to build, and every way
    /// the window can change moves at least one field of it.
    private struct DisplayKey: Equatable {
        var epoch: UInt64
        var count: Int
        var firstSeq: UInt64?
        var lastSeq: UInt64?
        var backend: String?
    }

    @ObservationIgnored private var displayCache: [ChatDisplayItem] = []
    @ObservationIgnored private var displayKey: DisplayKey?

    /// Show the prompt in the transcript the moment Send is pressed.
    @discardableResult
    private func stageOutgoing(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = "outgoing-\(UUID().uuidString)"
        outgoing.append(ChatDisplayItem(id: id, kind: .user(trimmed)))
        outgoingWatermark[id] = events.compactMap(\.seq).max()
        return id
    }

    private func dropOutgoing(_ id: String?) {
        guard let id else { return }
        outgoing.removeAll { $0.id == id }
        outgoingWatermark.removeValue(forKey: id)
    }

    /// Newest archive seq seen when each prompt was staged, by staged id.
    /// A text match only counts when it is newer than the send: without this
    /// a repeated prompt ("hi" twice) is dropped by the older copy, and a
    /// host that echoes the text in another form would leave a ghost bubble
    /// that never matches. Hosts without seq fall back to text matching.
    @ObservationIgnored private var outgoingWatermark: [String: UInt64?] = [:]

    /// Drop staged prompts the archive has now given back.
    ///
    /// The stored text can grow a suffix (attachment names), so a prefix
    /// match still counts as the same send. A newer user record also drops
    /// the bubble even when the text matches nothing: the host moved past
    /// this send, so whatever it stored is this prompt under some form.
    private func reconcileOutgoing() {
        guard !outgoing.isEmpty else { return }
        let userSeqs: [UInt64?] = events.lazy
            .filter { $0.kind == "user" }
            .map { $0.seq }
        outgoing.removeAll { item in
            guard case let .user(text) = item.kind else {
                outgoingWatermark.removeValue(forKey: item.id)
                return true
            }
            let watermark = outgoingWatermark[item.id] ?? nil
            let matched = events.contains { event in
                guard event.kind == "user", let held = event.text else { return false }
                guard held == text || held.hasPrefix(text) else { return false }
                // Same text sent before is not this send arriving.
                if let seq = event.seq, let watermark { return seq > watermark }
                return true
            }
            // The host stored something newer from this person. Sends are
            // serialized, so that record is this send under another form.
            let movedPast = userSeqs.contains { seq in
                guard let seq, let watermark else { return false }
                return seq > watermark
            }
            if matched || movedPast { outgoingWatermark.removeValue(forKey: item.id) }
            return matched || movedPast
        }
    }

    /// Bumped whenever the window is replaced rather than grown. A host older
    /// than `seq` gives its records no identity of their own, and two
    /// different windows of the same size would otherwise look like one.
    @ObservationIgnored private var eventsEpoch: UInt64 = 0

    /// Everything a window of the timeline is, forgotten in one place.
    private func forgetWindow() {
        eventsEpoch &+= 1
        offset = 0
        conversationUsage = nil
        usageThrough = 0
        earlierCursor = nil
        hasEarlier = false
        loadingEarlier = false
        earlierInFlight = false
        reachedStart = false
    }

    /// Open a conversation on its newest page rather than on its beginning.
    ///
    /// A conversation is read from the end because that is where a person
    /// starts reading it. What comes before is fetched a page at a time as
    /// they scroll back, so opening a long chat costs one bounded read
    /// whatever is behind it.
    ///
    /// A backend that streams in small pieces can spend a page of records on
    /// a handful of rows, so a page that coalesces into almost nothing pulls
    /// the one before it, up to a small bound. Nobody should open a chat and
    /// find one paragraph in it.
    private func openEvents(id: String, generation: UInt64) async {
        guard !pagingUnavailable else {
            await loadEvents(id: id, reset: true, generation: generation)
            return
        }
        do {
            let page = try await Bridge.chatEventPage(
                id: id, cursor: nil, limit: Self.openPageEvents, peer: peer
            )
            guard selectionMatches(id: id, generation: generation) else { return }
            eventsEpoch &+= 1
            events = page.events
            reconcileOutgoing()
            offset = page.nextOffset
            earlierCursor = page.cursor
            hasEarlier = page.hasEarlier
            conversationUsage = page.usage
            usageThrough = page.nextOffset
            // Opened where the archive begins, with content on screen: say
            // so. Otherwise a fully loaded conversation is indistinguishable
            // from one stuck mid-history. Empty chats stay quiet.
            if !page.hasEarlier, !page.events.isEmpty { reachedStart = true }
            warmMarkdown()
            settleNotifications()
            var pulled = 0
            while displayItems.count < Self.openDisplayItems,
                  hasEarlier,
                  pulled < Self.openExtraPages {
                pulled += 1
                await loadEarlier(id: id, generation: generation, quiet: true)
                guard selectionMatches(id: id, generation: generation) else { return }
            }
            await loadResponseAttachments(id: id, generation: generation)
        } catch {
            if isUnknownMethod(error) { pagingUnavailable = true }
            guard selectionMatches(id: id, generation: generation) else { return }
            // Whatever went wrong, the conversation still has to appear. The
            // whole-timeline read is the behaviour every host has had.
            await loadEvents(id: id, reset: true, generation: generation)
        }
    }

    /// Pull the page before the oldest one held, and put it in front.
    ///
    /// Called by the transcript as the top comes near, so the page is usually
    /// already there by the time somebody reaches it.
    func loadEarlier() async {
        guard let selected else { return }
        await loadEarlier(id: selected.id, generation: selectionGeneration, quiet: false)
    }

    private func loadEarlier(id: String, generation: UInt64, quiet: Bool) async {
        guard !pagingUnavailable, hasEarlier, !earlierInFlight,
              let cursor = earlierCursor
        else { return }
        earlierInFlight = true
        loadingEarlier = !quiet
        defer {
            earlierInFlight = false
            loadingEarlier = false
        }
        do {
            let page = try await Bridge.chatEventPage(
                id: id, cursor: cursor, limit: Self.pageEvents, peer: peer
            )
            guard selectionMatches(id: id, generation: generation) else { return }
            if page.reset {
                // The archive was trimmed while this was in flight, so the
                // offsets under the cursor no longer mean anything. This page
                // is the newest one: take it as the whole window rather than
                // putting it in front of records it now sits after.
                eventsEpoch &+= 1
                events = page.events
                reconcileOutgoing()
                offset = page.nextOffset
                conversationUsage = page.usage
                usageThrough = page.nextOffset
                warmMarkdown()
            } else {
                // Pages do not overlap, but a trim or a retry could still put
                // a record in two answers. Identity is the record's place in
                // the archive, so a repeat is cheap to spot.
                let oldest = events.first?.seq ?? UInt64.max
                let fresh = page.events.filter { ($0.seq ?? 0) < oldest }
                events.insert(contentsOf: fresh, at: 0)
                warmMarkdown()
            }
            // Always, even for a page that carried nothing this window can
            // use. The cursor is how the walk moves: keeping the old one
            // means asking the same question on every frame of every scroll
            // and never reaching the beginning.
            earlierCursor = page.cursor
            hasEarlier = page.hasEarlier
            if !hasEarlier { reachedStart = true }
            await loadResponseAttachments(id: id, generation: generation)
        } catch {
            if isUnknownMethod(error) { pagingUnavailable = true }
        }
    }

    /// Whether this host is simply older than the method that was called.
    ///
    /// A coded answer where the host has one, and the sentence where it does
    /// not: a build that predates the code still has to be recognised, and it
    /// is the only reason this fallback exists at all.
    private func isUnknownMethod(_ error: Error) -> Bool {
        if case let BridgeError.core(code, message) = error {
            return code == "unknown_method" || message.hasPrefix("unknown ")
        }
        return false
    }

    /// How many records a conversation opens on. Records, not rows: streamed
    /// text arrives in many pieces and becomes one paragraph.
    ///
    /// Large, and it used to be small for a reason that turned out to be
    /// backwards. The cost that hurts is not the number of rows, it is the
    /// number of *insertions*: each one changes the content height, and a
    /// changed content height makes the lazy stack resolve estimates for the
    /// rows in between, which means building them and measuring their text.
    /// So a page that reads four times as much history costs one of those
    /// walks where four small pages cost four. Five hundred is the host's own
    /// ceiling on `chat.eventPage`, so asking for more only asks for this.
    private static let openPageEvents = 500
    /// How many records each older page carries.
    ///
    /// Nearly as large as the opening page, for the same reason. A backend
    /// that streams spends hundreds of records on a handful of paragraphs,
    /// and pulling fifty of them at a time meant a chat of any length was
    /// read back in dozens of insertions, each one a walk over the rows and a
    /// correction of the reader's place.
    private static let pageEvents = 400
    /// The rows an opening window aims to hold before it stops pulling.
    ///
    /// A conversation should open with something to read behind it, not with
    /// the last answer alone. Two dozen was a screen at best and, on a
    /// backend that folds a whole page into one turn, a single row.
    private static let openDisplayItems = 60
    /// How many extra pages one opening may pull to reach that.
    private static let openExtraPages = 6

    private func loadEvents(id: String, reset: Bool, generation: UInt64, quiet: Bool = false) async {
        let requestedOffset = reset ? 0 : offset
        do {
            let chunk = try await Bridge.chatEvents(id: id, offset: requestedOffset, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            guard reset || requestedOffset == offset else { return }
            // A poll that found nothing new must not write anything back. The
            // write is what redraws the transcript, and most polls of a
            // running turn arrive between records rather than on one.
            if !reset, chunk.events.isEmpty, chunk.nextOffset == offset {
                await loadResponseAttachments(id: id, generation: generation)
                return
            }
            if reset {
                eventsEpoch &+= 1
                events = chunk.events
                // The whole timeline, so there is nothing before it. Say so
                // when there is something on screen; empty chats stay quiet.
                earlierCursor = nil
                hasEarlier = false
                if !chunk.events.isEmpty { reachedStart = true }
            } else {
                events.append(contentsOf: chunk.events)
            }
            reconcileOutgoing()
            offset = chunk.nextOffset
            settleNotifications()
            await loadResponseAttachments(id: id, generation: generation)
        } catch {
            // Background polls must not pop an error banner on an idle
            // screen; user-initiated loads still surface.
            if !quiet, selectionMatches(id: id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    func clearCachedAttachmentMemory() {
        attachmentCacheGeneration &+= 1
        responseAttachmentData = [:]
        attachmentPreviews = [:]
        loadingResponseAttachments = []
        responseAttachmentErrors = [:]
        // Also stop the remainder of a background page's download queue.
        attemptedResponseAttachments.formUnion(events.compactMap { timeline in
            guard timeline.event?.kind == "attachment" else { return nil }
            return timeline.event?.id
        })
    }

    func downloadResponseAttachment(_ attachment: ChatAttachment) async {
        guard let selected else { return }
        await loadResponseAttachment(
            attachment, id: selected.id, generation: selectionGeneration, userInitiated: true
        )
    }

    private func loadResponseAttachments(id: String, generation: UInt64) async {
        let descriptors = events.compactMap { timeline -> ChatAttachment? in
            guard let event = timeline.event,
                  event.kind == "attachment",
                  let attachmentID = event.id,
                  !attemptedResponseAttachments.contains(attachmentID)
            else { return nil }
            return ChatAttachment(
                id: attachmentID,
                name: event.name ?? "Attachment",
                mediaType: event.mediaType,
                size: event.size
            )
        }
        // Keep background downloads bounded instead of fetching a whole page
        // of files concurrently. Navigation stops the remaining queue.
        for descriptor in descriptors {
            guard selectionMatches(id: id, generation: generation) else { return }
            await loadResponseAttachment(descriptor, id: id, generation: generation, userInitiated: false)
        }
    }

    private func loadResponseAttachment(
        _ attachment: ChatAttachment, id: String, generation: UInt64, userInitiated: Bool
    ) async {
        guard selectionMatches(id: id, generation: generation),
              responseAttachmentData[attachment.id] == nil,
              !loadingResponseAttachments.contains(attachment.id),
              userInitiated || !attemptedResponseAttachments.contains(attachment.id)
        else { return }
        let targetPeer = peer
        let memoryGeneration = attachmentCacheGeneration
        attemptedResponseAttachments.insert(attachment.id)
        loadingResponseAttachments.insert(attachment.id)
        responseAttachmentErrors[attachment.id] = nil
        defer {
            if selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration {
                loadingResponseAttachments.remove(attachment.id)
            }
        }
        let cacheEpoch = await ChatAttachmentCache.shared.epoch()
        guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration else { return }
        if let cached = await ChatAttachmentCache.shared.read(peer: targetPeer, chat: id, attachment: attachment.id) {
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration else { return }
            responseAttachmentData[attachment.id] = cached
            return
        }
        guard selectionMatches(id: id, generation: generation),
              userInitiated || ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: attachment.size)
        else { return }
        do {
            let payload = try await Bridge.chatAttachment(id: id, attachmentID: attachment.id, peer: targetPeer)
            guard let data = Data(base64Encoded: payload.data), !data.isEmpty,
                  data.count <= ChatInbox.maxBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard await ChatAttachmentCache.shared.write(data, peer: targetPeer, chat: id, attachment: attachment.id, epoch: cacheEpoch) else { return }
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration else { return }
            responseAttachmentData[attachment.id] = data
        } catch {
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration else { return }
            responseAttachmentErrors[attachment.id] = Self.downloadFailure(error)
        }
    }

    /// What the card says when a file does not arrive.
    ///
    /// A retry is only worth offering when trying again could work. The host
    /// refuses a file over its transfer cap and one it can no longer find,
    /// and both of those answers are the same every time they are asked, so
    /// they are reported as they are rather than as "Tap to retry".
    private static func downloadFailure(_ error: Error) -> String {
        let reason = error.localizedDescription
        if reason.contains("quota_exceeded") {
            return "Relay allowance reached. A direct connection can still transfer this file."
        }
        if reason.localizedCaseInsensitiveContains("too large") {
            return "This file is too large to transfer. Open it on the computer that made it."
        }
        if reason.localizedCaseInsensitiveContains("no longer available") {
            return "This file is no longer on the computer that made it."
        }
        return "Download failed. Tap to retry."
    }

    /// The brief and the one rule tokenstat adds. Reloaded whenever either
    /// could have moved: a different conversation, a new backend (which changes
    /// how the text travels), or an edited brief.
    private func loadInstructions(id: String, generation: UInt64) async {
        do {
            let loaded = try await Bridge.chatInstructions(id: id, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            instructions = loaded
        } catch {
            // Not worth an alert. The inspector simply shows nothing rather
            // than interrupting a conversation over a disclosure nobody opened.
            if selectionMatches(id: id, generation: generation) { instructions = nil }
        }
    }

    private func loadApprovals(id: String, generation: UInt64) async {
        do {
            let loaded = try await Bridge.chatApprovals(id: id, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            // Unchanged approvals must not write back: the write redraws the
            // transcript, and this runs on every poll of a running turn.
            if approvals != loaded { approvals = loaded }
            settleNotifications()
        } catch {
            if selectionMatches(id: id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    private func selectionMatches(id: String, generation: UInt64) -> Bool {
        selectionGeneration == generation && selected?.id == id
            && continuityScope == WorkSessionContext.shared.scope
    }

    private func replace(_ chat: ChatConversation) {
        if selected?.id == chat.id {
            selected = chat
        }
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.insert(chat, at: 0)
        }
        chats.sort { $0.updatedAtMs > $1.updatedAtMs }
        if let folderID { storeChatListCache(chats, folderID: folderID) }
        saveLaunchChoice(from: chat)
        settleNotifications()
    }

    private func settleNotifications() {
        #if os(macOS)
        let done = events.reversed().lazy.compactMap { timeline -> String? in
            guard timeline.kind == "agent", timeline.event?.kind == "done" else { return nil }
            return timeline.event?.status
        }.first
        RunNotifications.shared.settle(
            chats: chats,
            approvals: approvals,
            selectedID: selected?.id,
            selectedDoneStatus: done
        )
        #endif
    }

    /// The persona a new chat should start with, or nil to take the
    /// workspace default.
    ///
    /// Every other setup control is carried over from the last conversation.
    /// The persona was not, so choosing no persona and then pressing plus
    /// handed you a persona again, and the choice looked like it had not
    /// saved.
    ///
    /// The remembered id is checked against this workspace's list before it is
    /// used. One choice is stored for the app rather than one per folder, and
    /// a persona belonging to another folder is not available here, so an
    /// unrecognised id falls back to this folder's own answer. "No persona"
    /// needs no such check: it is a choice about this person, not about a
    /// folder, and it travels.
    private func rememberedPersonaID(_ saved: LaunchChoice?) -> String? {
        guard let remembered = saved?.personaID else { return nil }
        if remembered.isEmpty { return "" }
        guard personas.contains(where: { $0.id == remembered }) else { return nil }
        return remembered
    }

    private var lastLaunchChoice: LaunchChoice? {
        guard let data = UserDefaults.standard.data(forKey: Self.launchChoiceKey) else { return nil }
        return try? JSONDecoder().decode(LaunchChoice.self, from: data)
    }

    private func loadQueue(for id: String?) {
        persistQueue()
        queuedConversationID = id
        guard let id else {
            queued = []
            return
        }
        queued = Self.storedQueue(for: id)
    }

    private static func storedQueue(for id: String) -> [ChatQueuedMessage] {
        guard let data = UserDefaults.standard.data(forKey: Self.queueKeyPrefix + id),
            let items = try? JSONDecoder().decode([ChatQueuedMessage].self, from: data)
        else {
            return []
        }
        return items
    }

    /// Write an item back to the conversation that owns it, without touching
    /// the live queue (which now belongs to another conversation).
    private static func reappendToStoredQueue(
        _ item: ChatQueuedMessage, at index: Int, conversationID: String
    ) {
        var stored = storedQueue(for: conversationID)
        if !stored.contains(where: { $0.id == item.id }) {
            stored.insert(item, at: min(max(0, index), stored.count))
        }
        let key = Self.queueKeyPrefix + conversationID
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func persistQueue() {
        guard let id = queuedConversationID else { return }
        let key = Self.queueKeyPrefix + id
        if queued.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(queued) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveLaunchChoice(from chat: ChatConversation) {
        let choice = LaunchChoice(
            backend: chat.backend,
            model: chat.model,
            effort: chat.effort,
            mode: chat.mode,
            autonomy: chat.autonomy,
            // Empty, not nil: a conversation with no persona is a choice worth
            // carrying, and nil already means "nothing recorded".
            personaID: chat.personaID ?? ""
        )
        guard let data = try? JSONEncoder().encode(choice) else { return }
        UserDefaults.standard.set(data, forKey: Self.launchChoiceKey)
    }
}

struct ChatToolState: Equatable {
    var callId: String
    var verb: String
    var target: String
    var running: Bool
    var failed: Bool
    var detail: String?
    var startedAtMs: Int64
    var endedAtMs: Int64?
    /// Display lines, split once at construction. `snippet` used to split
    /// the whole detail on every read, and a row reads it half a dozen
    /// times per draw: Codex shell outputs reach megabytes, so one live
    /// row cost several full multi-megabyte splits per poll.
    var snippet: [String]

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    static func isFileEditVerb(_ verb: String) -> Bool {
        verb == "Edit" || verb == "NotebookEdit"
    }

    /// Display lines for one detail string, split once. See `snippet`.
    static func makeSnippet(verb: String, detail: String?) -> [String] {
        guard let detail, !detail.isEmpty else { return [] }
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // An edit's red/green lines must reach the row unprefixed: a blanket
        // "| " is what made every Tool row read as grey output and broke the
        // Show edit label. This covers both the old/new rendering ("- old")
        // and unified patches ("-hello", "@@" hunks stay grey). Other verbs
        // keep the output marker on every line, so a shell trace like
        // "+ set -x" never poses as a diff.
        // Codex often exposes a unified patch through a command_execution
        // item. Treat Diff like a native edit so +/- lines remain visible and
        // receive the same semantic coloring as Edit/NotebookEdit cards.
        let diffVerbs = ["Edit", "NotebookEdit", "Diff"]
        let isDiff = diffVerbs.contains(verb)
        var out = lines.prefix(Self.snippetLineCap).map { line in
            let shown = Self.clip(line)
            if isDiff, Self.isDiffLine(shown) {
                return shown
            }
            return "| \(shown)"
        }
        if lines.count > Self.snippetLineCap {
            out.append("| … (\(lines.count - Self.snippetLineCap) more)")
        }
        return Array(out)
    }

    /// A unified or old/new diff body line. File headers ("--- a/…",
    /// "+++ b/…") are not changes and stay grey.
    static func isDiffLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        guard first == "+" || first == "-" else { return false }
        return !(line.hasPrefix("+++ ") || line.hasPrefix("--- "))
    }

    /// Cut one line down to what a row can draw.
    ///
    /// The line cap alone bounds the wrong half. A line is whatever sits
    /// between two newlines, and a tool that answers in JSON answers in one
    /// line however many kilobytes it is: a web search result arrives as a
    /// single forty-kilobyte string. Handing that to one `Text` in a stack
    /// that grows to fit means laying out forty thousand characters, with
    /// wrapping, on every measuring pass the lazy stack makes.
    ///
    /// That is the hang. It is per row and not per transcript, which is why
    /// it survived every bound put on the number of rows: thirty-seven rows
    /// took a second and a half, and a dozen took a third of one.
    ///
    /// The full text stays in `detail`, so copy still yields everything.
    static func clip(_ line: String) -> String {
        guard line.count > Self.snippetColumnCap else { return line }
        return String(line.prefix(Self.snippetColumnCap)) + "…"
    }

    /// A 500-line stdout must not become 500 rows. The full text stays in
    /// `detail` for copy; the row only ever draws this many.
    private static let snippetLineCap = 60
    /// And how much of one line is drawn.
    ///
    /// Roughly four wrapped lines of the row's monospace face in a full-width
    /// reading lane, so ordinary output, long shell commands and minified
    /// source all still read as themselves. What it stops is the single line
    /// that is really a document.
    private static let snippetColumnCap = 600
}

/// A file the agent changed. One card, not a tool row plus a second copy.
struct ChatEditState: Equatable {
    var path: String
    var added: UInt32
    var removed: UInt32
    var patch: String
    /// 1-based count of this path since the last user message. 2 means this
    /// file was already edited earlier in the same turn.
    var revision: Int
    var running: Bool
    var failed: Bool
    var startedAtMs: Int64
    var endedAtMs: Int64?

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    var fileName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Last two folders of the parent path, enough to tell two same-named
    /// files apart without drawing the whole absolute path as the title.
    var location: String {
        let folder = (path as NSString).deletingLastPathComponent
        let last = (folder as NSString).lastPathComponent
        let grand = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if last.isEmpty || last == "/" { return "" }
        if grand.isEmpty || grand == "/" { return last }
        return "\(grand)/\(last)"
    }

    /// Nil on the first change of a file in a turn. Later ones name themselves.
    var changeLabel: String? {
        guard revision >= 2 else { return nil }
        return "\(ChatClock.ordinal(revision)) change"
    }

    mutating func applyPatch(added: UInt32, removed: UInt32, patch: String) {
        if added > 0 { self.added = added }
        if removed > 0 { self.removed = removed }
        if !patch.isEmpty { self.patch = patch }
        recountIfNeeded()
    }

    mutating func applyDetail(_ detail: String?) {
        guard patch.isEmpty, let detail, !detail.isEmpty else { return }
        patch = detail
        recountIfNeeded()
    }

    mutating func recountIfNeeded() {
        guard added == 0, removed == 0, !patch.isEmpty else { return }
        var plus: UInt32 = 0
        var minus: UInt32 = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let shown = String(line)
            guard ChatToolState.isDiffLine(shown), let first = shown.first else { continue }
            if first == "+" { plus += 1 }
            if first == "-" { minus += 1 }
        }
        added = plus
        removed = minus
    }
}

enum ChatClock {
    static func duration(from startedAtMs: Int64, to endedAtMs: Int64?) -> String? {
        guard let endedAtMs else { return nil }
        let ms = max(0, endedAtMs - startedAtMs)
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(Int(seconds.rounded()))s"
    }

    static func ordinal(_ value: Int) -> String {
        let mod100 = value % 100
        let mod10 = value % 10
        if (11...13).contains(mod100) { return "\(value)th" }
        switch mod10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}

/// A message waiting for the current turn to finish.
struct ChatQueuedMessage: Identifiable, Equatable, Codable {
    var id: String
    var text: String
    var attachments: [ChatAttachment]
}

/// Equatable so a transcript can skip the rows that did not move. A chat
/// redraws whenever anything about it changes, and without this every visible
/// row rebuilds itself because one of them grew by a word.
struct ChatDisplayItem: Identifiable, Equatable {
    let id: String
    let kind: Kind

    enum Kind: Equatable {
        case user(String)
        case assistant(String, backend: String?)
        case turnSeparator(String)
        /// A conversation changing hands, with the summary the incoming agent
        /// was given so the person can read exactly what it was told.
        case handoff(to: String, brief: String)
        case thinking(String)
        case tool(ChatToolState)
        case edit(ChatEditState)
        case attachment(ChatAttachment)
        case approval(ChatApproval)
        case usage(input: UInt64, output: UInt64, cost: Double?)
        case failed(String)
    }

    /// A name for a row that survives an older page arriving in front of it.
    ///
    /// The record's place in the archive when the host reports one, which is
    /// fixed for the life of that record. Without it the row is named by its
    /// position in the list, which is what it always was, and what makes a
    /// prepend re-identify every row below it.
    private static func stamp(_ event: ChatTimelineEvent, _ position: Int) -> String {
        if let seq = event.seq { return "s\(seq)" }
        return "\(event.atMs ?? 0)-\(position)"
    }

    static func coalesce(_ events: [ChatTimelineEvent], defaultBackend: String? = nil) -> [ChatDisplayItem] {
        var items: [ChatDisplayItem] = []
        var toolIndex: [String: Int] = [:]
        // How many times each call id has already started a tool in this
        // conversation. An agent is supposed to name every call something of
        // its own, and most do, but Antigravity sends `call_id: "tool"` for
        // all of them.
        var toolStarts: [String: Int] = [:]
        // Same duplicate-id hazard as tools, for edits that carry a reused
        // call id (or none and the same path twice). Row ids feed ForEach.
        var editStarts: [String: Int] = [:]
        var approvalIndex: [String: Int] = [:]
        var text = ""
        var textID = ""
        var textBackend: String?
        var thinking = ""
        var thinkingID = ""
        var lastBackend: String?
        var editRevisions: [String: Int] = [:]

        func flushText() {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(
                    ChatDisplayItem(
                        id: textID,
                        kind: .assistant(body, backend: textBackend ?? defaultBackend)
                    )
                )
            }
            text = ""
            textID = ""
            textBackend = nil
        }

        func flushThinking() {
            let body = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(ChatDisplayItem(id: thinkingID, kind: .thinking(body)))
            }
            thinking = ""
            thinkingID = ""
        }

        func closeRunningTools(failed: Bool, at: Int64?, detail: String?) {
            for index in items.indices {
                switch items[index].kind {
                case .tool(var state) where state.running:
                    state.running = false
                    state.failed = failed
                    if state.detail == nil {
                        state.detail = detail
                        state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: detail)
                    }
                    state.endedAtMs = at
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                case .edit(var state) where state.running:
                    state.running = false
                    state.failed = failed
                    state.endedAtMs = at
                    state.applyDetail(detail)
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                default:
                    continue
                }
            }
        }

        func nextEditRevision(_ path: String) -> Int {
            let key = path
            let n = (editRevisions[key] ?? 0) + 1
            editRevisions[key] = n
            return n
        }

        func matchingEditIndex(callId: String, path: String) -> Int? {
            if !callId.isEmpty, let index = toolIndex[callId], items.indices.contains(index) {
                switch items[index].kind {
                case let .edit(state) where path.isEmpty || state.path == path || state.path == "File":
                    return index
                case let .tool(state)
                    where ChatToolState.isFileEditVerb(state.verb)
                        && (path.isEmpty || state.target == path || state.target.isEmpty):
                    return index
                default:
                    break
                }
            }
            for index in items.indices.reversed() {
                switch items[index].kind {
                case let .edit(state) where state.running && (path.isEmpty || state.path == path):
                    return index
                case let .tool(state)
                    where state.running
                        && ChatToolState.isFileEditVerb(state.verb)
                        && (path.isEmpty || state.target == path):
                    return index
                default:
                    continue
                }
            }
            return nil
        }

        for event in events {
            if event.kind == "user" {
                flushText()
                flushThinking()
                editRevisions = [:]
                items.append(
                    ChatDisplayItem(
                        id: "user-\(stamp(event, items.count))",
                        kind: .user(event.text ?? "")
                    )
                )
                continue
            }
            if event.kind == "handoff" {
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "handoff-\(stamp(event, items.count))",
                        kind: .handoff(to: event.to ?? "", brief: event.brief ?? "")
                    )
                )
                // The separator would say the same thing twice, less well.
                lastBackend = event.to ?? lastBackend
                continue
            }
            if let approval = event.approval {
                flushText()
                flushThinking()
                // The timeline records an approval twice: once when the agent
                // paused, and again with the answer. Keep the row in the place
                // it happened and let the later state win, so a conversation
                // reopened tomorrow shows the outcome rather than a question
                // that looks like it is still waiting.
                let rowID = "approval-\(approval.id)"
                if let at = approvalIndex[rowID] {
                    items[at] = ChatDisplayItem(id: rowID, kind: .approval(approval))
                } else {
                    approvalIndex[rowID] = items.count
                    items.append(ChatDisplayItem(id: rowID, kind: .approval(approval)))
                }
                continue
            }
            guard let agent = event.event else { continue }
            let eventBackend = event.backend ?? defaultBackend
            if let eventBackend, let lastBackend, eventBackend != lastBackend {
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "turn-\(stamp(event, items.count))",
                        kind: .turnSeparator(eventBackend)
                    )
                )
            }
            if let eventBackend { lastBackend = eventBackend }
            switch agent.kind {
            case "text":
                flushThinking()
                if text.isEmpty {
                    textID = "text-\(stamp(event, items.count))"
                    textBackend = event.backend ?? defaultBackend
                }
                text += agent.delta ?? ""
            case "thinking":
                flushText()
                if thinking.isEmpty { thinkingID = "think-\(stamp(event, items.count))" }
                thinking += agent.delta ?? ""
            case "toolStart":
                flushText()
                flushThinking()
                let callId = agent.callId ?? "tool-\(stamp(event, items.count))"
                // Every tool row needs an identity of its own. `ForEach` is
                // keyed on it, and a list where fourteen rows answer to
                // "tool-tool" lays out fourteen slots and draws one, which is
                // the tall blank stretch in the middle of an Antigravity
                // transcript. The call id still matches an end to its start,
                // so only the row's name changes here, and it changes only
                // for the second and later use of a repeated id: an agent
                // that names its calls properly keeps the ids it has.
                let occurrence = (toolStarts[callId] ?? 0) + 1
                toolStarts[callId] = occurrence
                let rowID = occurrence == 1 ? "tool-\(callId)" : "tool-\(callId)#\(occurrence)"
                let verb = agent.verb ?? "Tool"
                let target = ChatToolState.clip(agent.target ?? "")
                toolIndex[callId] = items.count
                if ChatToolState.isFileEditVerb(verb) {
                    items.append(
                        ChatDisplayItem(
                            id: rowID,
                            kind: .edit(
                                ChatEditState(
                                    path: target.isEmpty ? "File" : target,
                                    added: 0,
                                    removed: 0,
                                    patch: "",
                                    revision: nextEditRevision(target.isEmpty ? "File" : target),
                                    running: true,
                                    failed: false,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: nil
                                )
                            )
                        )
                    )
                } else {
                    items.append(
                        ChatDisplayItem(
                            id: rowID,
                            kind: .tool(
                                ChatToolState(
                                    callId: callId,
                                    verb: verb,
                                    // Same reason as the snippet: a shell "target"
                                    // is the whole command, and a heredoc makes
                                    // that a document. `lineLimit` bounds what
                                    // is drawn, not what is measured.
                                    target: target,
                                    running: true,
                                    failed: false,
                                    detail: nil,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: nil,
                                    snippet: []
                                )
                            )
                        )
                    )
                }
            case "toolEnd":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                if let index = toolIndex[callId] {
                    switch items[index].kind {
                    case .tool(var state):
                        state.running = false
                        state.failed = !(agent.ok ?? true)
                        state.detail = agent.detail
                        state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: agent.detail)
                        state.endedAtMs = event.atMs
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                    case .edit(var state):
                        state.running = false
                        state.failed = !(agent.ok ?? true)
                        state.endedAtMs = event.atMs
                        state.applyDetail(agent.detail)
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    default:
                        break
                    }
                } else if ChatToolState.isFileEditVerb(agent.verb ?? "") {
                    let path = {
                        let clipped = ChatToolState.clip(agent.target ?? "")
                        return clipped.isEmpty ? "File" : clipped
                    }()
                    var state = ChatEditState(
                        path: path,
                        added: 0,
                        removed: 0,
                        patch: "",
                        revision: nextEditRevision(path),
                        running: false,
                        failed: !(agent.ok ?? true),
                        startedAtMs: event.atMs ?? 0,
                        endedAtMs: event.atMs
                    )
                    state.applyDetail(agent.detail)
                    items.append(
                        ChatDisplayItem(
                            id: "edit-\(callId.isEmpty ? stamp(event, items.count) : callId)",
                            kind: .edit(state)
                        )
                    )
                } else {
                    let fallback = callId.isEmpty ? "end-\(stamp(event, items.count))" : callId
                    let fallbackVerb = agent.verb ?? "Tool"
                    items.append(
                        ChatDisplayItem(
                            id: "tool-\(fallback)",
                            kind: .tool(
                                ChatToolState(
                                    callId: fallback,
                                    verb: fallbackVerb,
                                    target: ChatToolState.clip(agent.target ?? ""),
                                    running: false,
                                    failed: !(agent.ok ?? true),
                                    detail: agent.detail,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: event.atMs,
                                    snippet: ChatToolState.makeSnippet(verb: fallbackVerb, detail: agent.detail)
                                )
                            )
                        )
                    )
                }
            case "edit":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                let path = agent.path ?? "File"
                let added = agent.added ?? 0
                let removed = agent.removed ?? 0
                let patch = agent.patch ?? ""
                if let index = matchingEditIndex(callId: callId, path: path) {
                    switch items[index].kind {
                    case .edit(var state):
                        state.applyPatch(added: added, removed: removed, patch: patch)
                        if state.path == "File", !path.isEmpty { state.path = path }
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    case .tool(let toolState):
                        var state = ChatEditState(
                            path: path,
                            added: added,
                            removed: removed,
                            patch: patch,
                            revision: nextEditRevision(path),
                            running: toolState.running,
                            failed: false,
                            startedAtMs: toolState.startedAtMs,
                            endedAtMs: toolState.running ? nil : (event.atMs ?? toolState.endedAtMs)
                        )
                        state.recountIfNeeded()
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    default:
                        break
                    }
                    if !callId.isEmpty { toolIndex[callId] = index }
                } else {
                    var state = ChatEditState(
                        path: path,
                        added: added,
                        removed: removed,
                        patch: patch,
                        revision: nextEditRevision(path),
                        running: false,
                        failed: false,
                        startedAtMs: event.atMs ?? 0,
                        endedAtMs: nil
                    )
                    state.recountIfNeeded()
                    let rowID: String = {
                        if callId.isEmpty { return "edit-\(stamp(event, items.count))" }
                        let occurrence = (editStarts[callId] ?? 0) + 1
                        editStarts[callId] = occurrence
                        return occurrence == 1 ? "edit-\(callId)" : "edit-\(callId)#\(occurrence)"
                    }()
                    if !callId.isEmpty { toolIndex[callId] = items.count }
                    items.append(ChatDisplayItem(id: rowID, kind: .edit(state)))
                }
            case "attachment":
                flushText()
                flushThinking()
                guard let id = agent.id else { continue }
                items.append(
                    ChatDisplayItem(
                        id: "attachment-\(id)",
                        kind: .attachment(
                            ChatAttachment(
                                id: id,
                                name: agent.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Attachment",
                                mediaType: agent.mediaType,
                                size: agent.size
                            )
                        )
                    )
                )
            case "usage":
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "usage-\(stamp(event, items.count))",
                        kind: .usage(
                            input: agent.input ?? 0,
                            output: agent.output ?? 0,
                            cost: agent.costUsd
                        )
                    )
                )
            case "failed":
                flushText()
                flushThinking()
                closeRunningTools(failed: true, at: event.atMs, detail: agent.text)
                items.append(
                    ChatDisplayItem(
                        id: "failed-\(stamp(event, items.count))",
                        kind: .failed(agent.text ?? "The turn failed")
                    )
                )
            case "done":
                flushText()
                flushThinking()
                let status = agent.status ?? ""
                // Only the host's process outcome can fail a turn. Older hosts
                // may still carry a backend-level "cancelled" marker from
                // grok; that describes its tool stream, not the person
                // pressing Stop and not a failed process.
                let failed = status == "error"
                closeRunningTools(failed: failed, at: event.atMs, detail: failed ? status : nil)
            default:
                continue
            }
        }
        flushText()
        flushThinking()
        return items
    }
}

enum ChatGateCopy {
    static func chip(_ tier: String?) -> String {
        switch tier {
        case "full": return "Approvals"
        case "rules": return "Rules"
        case "bypassOnly": return "Bypass only"
        default: return "Checking"
        }
    }

    static func explanation(_ tier: String?, bypass: Bool) -> String {
        if bypass {
            return "This agent can use its backend's bypass mode in this folder."
        }
        switch tier {
        case "full":
            return "tokenstat asks before every tool action, and the agent waits for your answer."
        case "rules":
            return "Saved permission rules run. Anything else is denied."
        case "bypassOnly":
            return "This backend has no tokenstat approval gate, so this chat can only run without asking."
        default:
            return "Checking this backend's permission support."
        }
    }
}
