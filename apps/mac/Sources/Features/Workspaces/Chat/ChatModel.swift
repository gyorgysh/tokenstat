// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

@MainActor @Observable
final class ChatModel {
    var chats: [ChatConversation] = []
    var selected: ChatConversation?
    var events: [ChatTimelineEvent] = []
    var approvals: [ChatApproval] = []
    var offset: UInt64 = 0
    var attachments: [ChatAttachment] = []
    /// Downsampled JPEG for the composer strip, keyed by attachment id.
    var attachmentPreviews: [String: Data] = [:]
    var backends: [ChatBackend] = []
    var personas: [ChatPersona] = []
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
            async let loadedPersonas = Bridge.chatPersonas(peer: route.peer)
            async let loadedChats = Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            let loaded = try await (loadedBackends, loadedPersonas, loadedChats)
            guard generation == loadGeneration else { return }
            backends = loaded.0
            personas = loaded.1
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
        approvals = []
        events = []
        offset = 0
        guard let chat else { return }
        await loadEvents(id: chat.id, reset: true, generation: generation)
        await loadApprovals(id: chat.id, generation: generation)
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
            let chosen = backends.first(where: { $0.id != "sh" }) ?? backends.first
            let chat = try await Bridge.createChat(
                workspaceID: workspaceID,
                backend: chosen?.id ?? "claude",
                mode: "plan",
                autonomy: chosen?.gateTier == "bypassOnly" ? "bypass" : "standard",
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
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    func applyPersona(_ persona: ChatPersona?) async {
        guard let persona else {
            await update(personaID: "", systemPrompt: "")
            return
        }
        await update(
            backend: persona.backend,
            model: persona.model ?? "",
            effort: persona.effort ?? "",
            mode: persona.defaultMode,
            autonomy: persona.defaultAutonomy,
            personaID: persona.id,
            systemPrompt: persona.systemPrompt
        )
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
            let saved = try await Bridge.saveChatPersona(persona, peer: peer)
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

    func poll() async {
        guard let selected, selected.running || hasRunningTool else { return }
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
        ChatDisplayItem.coalesce(events)
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
        } catch {
            if selectionMatches(id: id, generation: generation) {
                self.error = error.localizedDescription
            }
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
        case assistant(String)
        case thinking(String)
        case tool(ChatToolState)
        case edit(path: String, added: UInt32, removed: UInt32, patch: String)
        case approval(ChatApproval)
        case usage(input: UInt64, output: UInt64, cost: Double?)
        case failed(String)
    }

    static func coalesce(_ events: [ChatTimelineEvent]) -> [ChatDisplayItem] {
        var items: [ChatDisplayItem] = []
        var toolIndex: [String: Int] = [:]
        var text = ""
        var textID = ""
        var thinking = ""
        var thinkingID = ""

        func flushText() {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(ChatDisplayItem(id: textID, kind: .assistant(body)))
            }
            text = ""
            textID = ""
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
            if let approval = event.approval {
                flushText()
                flushThinking()
                items.append(ChatDisplayItem(id: "approval-\(approval.id)", kind: .approval(approval)))
                continue
            }
            guard let agent = event.event else { continue }
            switch agent.kind {
            case "text":
                flushThinking()
                if text.isEmpty { textID = "text-\(event.atMs ?? 0)-\(items.count)" }
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
                let failed = status == "cancelled" || status == "canceled" || status == "error"
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
            return "tokenstat asks before every tool action."
        case "rules":
            return "Saved permission rules run. Anything else is denied."
        case "bypassOnly":
            return "This backend has no tokenstat approval gate. Use Bypass only if you intend that."
        default:
            return "Checking this backend's permission support."
        }
    }
}
