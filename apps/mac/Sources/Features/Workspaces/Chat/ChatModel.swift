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
            offset = 0
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
            if let selected, chats.contains(where: { $0.id == selected.id }) {
                await select(chats.first(where: { $0.id == selected.id }) ?? selected)
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
        offset = 0
        guard let chat else { return }
        await loadEvents(id: chat.id, reset: true, generation: generation)
        await loadApprovals(id: chat.id, generation: generation)
        await loadInstructions(id: chat.id, generation: generation)
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
                mode: saved?.mode ?? "plan",
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

    func send(_ text: String) async {
        guard let selected else { return }
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
            chats = latest
            if let current = latest.first(where: { $0.id == selected.id }) {
                self.selected = current
            }
        } catch {}
    }

    func resolve(_ approval: ChatApproval, choice: String) async {
        let generation = selectionGeneration
        do {
            _ = try await Bridge.resolveChatApproval(id: approval.id, choice: choice, peer: peer)
            guard selectionMatches(id: approval.conversationID, generation: generation) else { return }
            await loadApprovals(id: approval.conversationID, generation: generation)
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

    func poll() async {
        guard let selected, selected.running || hasRunningTool || hasPendingResponseAttachments else { return }
        let generation = selectionGeneration
        await loadEvents(id: selected.id, reset: false, generation: generation)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        await loadApprovals(id: selected.id, generation: generation)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        do {
            let latest = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            chats = latest
            if let current = latest.first(where: { $0.id == selected.id }) {
                self.selected = current
            }
        } catch {}
    }

    var busy: Bool {
        selected?.running == true || hasRunningTool
    }

    var hasRunningTool: Bool {
        displayItems.contains { item in
            if case let .tool(state) = item.kind { return state.running }
            return false
        }
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

    var turnUsage: ChatUsageTotals? {
        let usages = events.compactMap(\.event).filter { $0.kind == "usage" }
        guard !usages.isEmpty else { return nil }
        return ChatUsageTotals(
            input: usages.reduce(0) { $0 + ($1.input ?? 0) },
            output: usages.reduce(0) { $0 + ($1.output ?? 0) },
            cacheRead: usages.reduce(0) { $0 + ($1.cacheRead ?? 0) },
            cacheWrite: usages.reduce(0) { $0 + ($1.cacheWrite ?? 0) },
            cost: usages.reduce(0) { $0 + ($1.costUsd ?? 0) }
        )
    }

    var hasStarted: Bool {
        !events.isEmpty || selected?.resumeToken != nil
    }

    /// Consecutive text and thinking deltas become one block each, and a
    /// ToolEnd lands on the ToolStart it belongs to so the row can show
    /// running, duration and failure without a second line.
    var displayItems: [ChatDisplayItem] {
        ChatDisplayItem.coalesce(events, defaultBackend: selected?.backend)
    }

    private func loadEvents(id: String, reset: Bool, generation: UInt64) async {
        let requestedOffset = reset ? 0 : offset
        do {
            let chunk = try await Bridge.chatEvents(id: id, offset: requestedOffset, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            guard reset || requestedOffset == offset else { return }
            if reset {
                events = chunk.events
            } else {
                events.append(contentsOf: chunk.events)
            }
            offset = chunk.nextOffset
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
            approvals = loaded
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

struct ChatToolState {
    var callId: String
    var verb: String
    var target: String
    var running: Bool
    var failed: Bool
    var detail: String?
    var startedAtMs: Int64
    var endedAtMs: Int64?

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

    var snippet: [String] {
        guard let detail, !detail.isEmpty else { return [] }
        return detail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "| \($0)" }
    }
}

struct ChatDisplayItem: Identifiable {
    let id: String
    let kind: Kind

    enum Kind {
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

    static func coalesce(_ events: [ChatTimelineEvent], defaultBackend: String? = nil) -> [ChatDisplayItem] {
        var items: [ChatDisplayItem] = []
        var toolIndex: [String: Int] = [:]
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
                if state.detail == nil { state.detail = detail }
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
                        id: "user-\(event.atMs ?? 0)-\(items.count)",
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
                        id: "handoff-\(event.atMs ?? 0)-\(items.count)",
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
                        id: "turn-\(event.atMs ?? 0)-\(items.count)",
                        kind: .turnSeparator(eventBackend)
                    )
                )
            }
            if let eventBackend { lastBackend = eventBackend }
            switch agent.kind {
            case "text":
                flushThinking()
                if text.isEmpty {
                    textID = "text-\(event.atMs ?? 0)-\(items.count)"
                    textBackend = event.backend ?? defaultBackend
                }
                text += agent.delta ?? ""
            case "thinking":
                flushText()
                if thinking.isEmpty { thinkingID = "think-\(event.atMs ?? 0)-\(items.count)" }
                thinking += agent.delta ?? ""
            case "toolStart":
                flushText()
                flushThinking()
                let callId = agent.callId ?? "tool-\(event.atMs ?? 0)-\(items.count)"
                let state = ChatToolState(
                    callId: callId,
                    verb: agent.verb ?? "Tool",
                    target: agent.target ?? "",
                    running: true,
                    failed: false,
                    detail: nil,
                    startedAtMs: event.atMs ?? 0,
                    endedAtMs: nil
                )
                toolIndex[callId] = items.count
                items.append(ChatDisplayItem(id: "tool-\(callId)", kind: .tool(state)))
            case "toolEnd":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                if let index = toolIndex[callId], case .tool(var state) = items[index].kind {
                    state.running = false
                    state.failed = !(agent.ok ?? true)
                    state.detail = agent.detail
                    state.endedAtMs = event.atMs
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                } else {
                    let fallback = callId.isEmpty ? "end-\(event.atMs ?? 0)-\(items.count)" : callId
                    items.append(
                        ChatDisplayItem(
                            id: "tool-\(fallback)",
                            kind: .tool(
                                ChatToolState(
                                    callId: fallback,
                                    verb: agent.verb ?? "Tool",
                                    target: agent.target ?? "",
                                    running: false,
                                    failed: !(agent.ok ?? true),
                                    detail: agent.detail,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: event.atMs
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
                        id: "edit-\(agent.callId ?? agent.path ?? "\(items.count)")",
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
                                name: agent.name ?? "Attachment",
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
                        id: "usage-\(event.atMs ?? 0)-\(items.count)",
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
                        id: "failed-\(event.atMs ?? 0)-\(items.count)",
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
