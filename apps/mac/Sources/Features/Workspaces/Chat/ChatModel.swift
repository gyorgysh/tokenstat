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
    /// Bumped when response bytes arrive. Views use this as an explicit
    /// invalidation point because a dictionary subscript mutation can be too
    /// subtle for a lazily rendered transcript row to observe.
    private(set) var responseAttachmentRevision: UInt64 = 0
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
    private var attemptedResponseAttachments: Set<String> = []
    private var loadingResponseAttachments: Set<String> = []
    private var responseAttachmentRetryAt: [String: Date] = [:]

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
        if folderID != workspaceID || self.workspaceID != route.workspaceID || self.peer != route.peer {
            chats = []
            selected = nil
            events = []
            approvals = []
            forgetWindow()
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
            guard generation == loadGeneration else { return }
            backends = loaded.0
            personas = loaded.1.personas
            // The host says "" for a workspace that has chosen no persona.
            // Nil here means the same thing, and every reader already handles
            // it, so the empty string never gets past this line.
            defaultPersonaID = loaded.1.defaultId.isEmpty ? nil : loaded.1.defaultId
            chats = loaded.2
            if let selected, let fresh = chats.first(where: { $0.id == selected.id }) {
                // This conversation is already open. Re-selecting it would
                // empty the transcript and read it back, which is a blank
                // pane, a persona where the last turn was, and a lost scroll
                // position every time somebody leaves this screen and comes
                // back to it. Take the fresh record and keep the rows.
                if fresh != selected { self.selected = fresh }
                await refreshOpen(id: fresh.id)
            } else if selectFirst {
                await select(chats.first)
            } else {
                await select(nil)
            }
        } catch {
            if generation == loadGeneration {
                self.error = error.localizedDescription
            }
        }
    }

    func select(_ chat: ChatConversation?) async {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selected = chat
        attachments = []
        attachmentPreviews = [:]
        responseAttachmentData = [:]
        responseAttachmentRevision &+= 1
        attemptedResponseAttachments = []
        loadingResponseAttachments = []
        responseAttachmentRetryAt = [:]
        approvals = []
        instructions = nil
        events = []
        forgetWindow()
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
        let context = loadGeneration
        do {
            try await Bridge.removeChat(id: chat.id, peer: peer)
            guard context == loadGeneration else { return }
            chats.removeAll { $0.id == chat.id }
            if selected?.id == chat.id {
                await select(chats.first)
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

    func send(_ text: String) async {
        guard let selected, !sending else { return }
        sending = true
        defer { sending = false }
        let generation = selectionGeneration
        let attachmentIDs = attachments.map(\.id)
        do {
            let updated = try await Bridge.sendChat(
                id: selected.id,
                text: text,
                attachmentIDs: attachmentIDs,
                peer: peer
            )
            guard selectionMatches(id: updated.id, generation: generation) else { return }
            replace(updated)
            attachments = []
            attachmentPreviews = [:]
            await loadEvents(id: updated.id, reset: false, generation: generation)
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
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
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        attachmentPreviews.removeValue(forKey: attachment.id)
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
            if chats != latest { chats = latest }
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
        await loadEvents(id: selected.id, reset: false, generation: generation)
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
            if chats != latest { chats = latest }
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
            if case let .tool(state) = item.kind { return state.running }
            return false
        }
        hasRunningToolCacheKey = displayKey
        hasRunningToolCacheValue = value
        return value
    }

    var hasPendingResponseAttachments: Bool {
        displayItems.contains { item in
            guard case let .attachment(attachment) = item.kind else { return false }
            return responseAttachmentData[attachment.id] == nil
        }
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
            if case let .tool(state) = item.kind { return state.running }
            return false
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
        if key == displayKey { return displayCache }
        displayCache = ChatDisplayItem.coalesce(events, defaultBackend: key.backend)
        displayKey = key
        return displayCache
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

    private func loadEvents(id: String, reset: Bool, generation: UInt64) async {
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
            offset = chunk.nextOffset
            settleNotifications()
            await loadResponseAttachments(id: id, generation: generation)
        } catch {
            if selectionMatches(id: id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    private func loadResponseAttachments(id: String, generation: UInt64) async {
        let descriptors = events.compactMap { timeline -> ChatAttachment? in
            guard let event = timeline.event,
                  event.kind == "attachment",
                  let attachmentID = event.id,
                  !attemptedResponseAttachments.contains(attachmentID),
                  !loadingResponseAttachments.contains(attachmentID),
                  responseAttachmentRetryAt[attachmentID, default: .distantPast] <= Date()
            else { return nil }
            return ChatAttachment(
                id: attachmentID,
                name: event.name ?? "Attachment",
                mediaType: event.mediaType,
                size: event.size
            )
        }
        guard !descriptors.isEmpty else { return }
        loadingResponseAttachments.formUnion(descriptors.map(\.id))
        let targetPeer = peer
        let loaded = await withTaskGroup(of: (String, Data)?.self, returning: [(String, Data)].self) { group in
            for descriptor in descriptors {
                group.addTask {
                    guard let payload = try? await Bridge.chatAttachment(
                        id: id,
                        attachmentID: descriptor.id,
                        peer: targetPeer
                    ), let data = Data(base64Encoded: payload.data) else { return nil }
                    return (descriptor.id, data)
                }
            }
            var values: [(String, Data)] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }
        loadingResponseAttachments.subtract(descriptors.map(\.id))
        guard selectionMatches(id: id, generation: generation) else { return }
        let loadedIDs = Set(loaded.map(\.0))
        var updatedData = responseAttachmentData
        for (attachmentID, data) in loaded {
            updatedData[attachmentID] = data
            attemptedResponseAttachments.insert(attachmentID)
        }
        if updatedData.count != responseAttachmentData.count {
            responseAttachmentData = updatedData
            responseAttachmentRevision &+= 1
        }
        for descriptor in descriptors where !loadedIDs.contains(descriptor.id) {
            responseAttachmentRetryAt[descriptor.id] = Date().addingTimeInterval(2)
        }
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
        guard let endedAtMs else { return nil }
        let ms = max(0, endedAtMs - startedAtMs)
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(Int(seconds.rounded()))s"
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
            if isDiff, Self.isDiffLine(line) {
                return line
            }
            return "| \(line)"
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

    /// A 500-line stdout must not become 500 rows. The full text stays in
    /// `detail` for copy; the row only ever draws this many.
    private static let snippetLineCap = 60
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
        case edit(path: String, added: UInt32, removed: UInt32, patch: String)
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
        var approvalIndex: [String: Int] = [:]
        var text = ""
        var textID = ""
        var textBackend: String?
        var thinking = ""
        var thinkingID = ""
        var lastBackend: String?

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
            for (_, index) in toolIndex {
                guard case .tool(var state) = items[index].kind, state.running else { continue }
                state.running = false
                state.failed = failed
                if state.detail == nil {
                    state.detail = detail
                    state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: detail)
                }
                state.endedAtMs = at
                items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
            }
        }

        for event in events {
            if event.kind == "user" {
                flushText()
                flushThinking()
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
                let state = ChatToolState(
                    callId: callId,
                    verb: agent.verb ?? "Tool",
                    target: agent.target ?? "",
                    running: true,
                    failed: false,
                    detail: nil,
                    startedAtMs: event.atMs ?? 0,
                    endedAtMs: nil,
                    snippet: []
                )
                toolIndex[callId] = items.count
                items.append(ChatDisplayItem(id: rowID, kind: .tool(state)))
            case "toolEnd":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                if let index = toolIndex[callId], case .tool(var state) = items[index].kind {
                    state.running = false
                    state.failed = !(agent.ok ?? true)
                    state.detail = agent.detail
                    state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: agent.detail)
                    state.endedAtMs = event.atMs
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
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
                                    target: agent.target ?? "",
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
                items.append(
                    ChatDisplayItem(
                        id: "edit-\(agent.callId ?? agent.path ?? stamp(event, items.count))",
                        kind: .edit(
                            path: agent.path ?? "File",
                            added: agent.added ?? 0,
                            removed: agent.removed ?? 0,
                            patch: agent.patch ?? ""
                        )
                    )
                )
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
