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
    private(set) var workspaceID: String?

    func count(in workspaceID: String) -> Int {
        guard self.workspaceID == workspaceID else { return 0 }
        return chats.count
    }

    func load(workspaceID: String) async {
        isLoading = true
        defer { isLoading = false }
        self.workspaceID = workspaceID
        do {
            async let loadedBackends = Bridge.chatBackends()
            async let loadedPersonas = Bridge.chatPersonas()
            async let loadedChats = Bridge.chats(workspaceID: workspaceID)
            backends = try await loadedBackends
            personas = try await loadedPersonas
            chats = try await loadedChats
            if let selected, chats.contains(where: { $0.id == selected.id }) {
                await select(chats.first(where: { $0.id == selected.id }) ?? selected)
            } else {
                await select(chats.first)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ chat: ChatConversation?) async {
        selected = chat
        attachments = []
        attachmentPreviews = [:]
        approvals = []
        events = []
        offset = 0
        guard let chat else { return }
        await loadEvents(id: chat.id, reset: true)
        await loadApprovals(id: chat.id)
    }

    func create() async {
        guard let workspaceID else { return }
        do {
            if backends.isEmpty {
                backends = try await Bridge.chatBackends()
            }
            let chosen = backends.first(where: { $0.id != "sh" }) ?? backends.first
            let chat = try await Bridge.createChat(
                workspaceID: workspaceID,
                backend: chosen?.id ?? "claude",
                mode: "plan",
                autonomy: chosen?.gateTier == "bypassOnly" ? "bypass" : "standard"
            )
            chats.insert(chat, at: 0)
            await select(chat)
        } catch {
            self.error = error.localizedDescription
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
                allowedShellPrefixes: allowedShellPrefixes
            )
            replace(updated)
        } catch {
            self.error = error.localizedDescription
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
        do {
            try await Bridge.removeChat(id: chat.id)
            chats.removeAll { $0.id == chat.id }
            if selected?.id == chat.id {
                await select(chats.first)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        guard let selected else { return }
        do {
            let updated = try await Bridge.sendChat(
                id: selected.id,
                text: text,
                attachmentIDs: attachments.map(\.id)
            )
            replace(updated)
            attachments = []
            attachmentPreviews = [:]
            await loadEvents(id: updated.id, reset: false)
        } catch {
            self.error = error.localizedDescription
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
        if item.data.count > ChatInbox.maxBytes {
            error = "An attachment is limited to 12 MB."
            return
        }
        do {
            let attachment = try await Bridge.attachToChat(
                id: selected.id,
                name: item.name,
                data: item.data,
                mediaType: item.mediaType
            )
            attachments.append(attachment)
            if let preview = ChatThumbnail.make(from: item.data) {
                attachmentPreviews[attachment.id] = preview
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        attachmentPreviews.removeValue(forKey: attachment.id)
    }

    func stop() async {
        guard let selected else { return }
        do {
            try await Bridge.stopChat(id: selected.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resolve(_ approval: ChatApproval, choice: String) async {
        do {
            _ = try await Bridge.resolveChatApproval(id: approval.id, choice: choice)
            await loadApprovals(id: approval.conversationID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func savePersona(_ persona: ChatPersona) async -> ChatPersona? {
        do {
            let saved = try await Bridge.saveChatPersona(persona)
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
            try await Bridge.removeChatPersona(id: persona.id)
            personas.removeAll { $0.id == persona.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func poll() async {
        guard let selected, selected.running else { return }
        await loadEvents(id: selected.id, reset: false)
        await loadApprovals(id: selected.id)
        do {
            let latest = try await Bridge.chats(workspaceID: selected.workspaceID)
            chats = latest
            if let current = latest.first(where: { $0.id == selected.id }) {
                self.selected = current
            }
        } catch {}
    }

    func backend(for id: String) -> ChatBackend? {
        backends.first { $0.id == id }
    }

    var turnUsage: (input: UInt64, output: UInt64, cost: Double)? {
        let usages = events.compactMap(\.event).filter { $0.kind == "usage" }
        guard !usages.isEmpty else { return nil }
        let input = usages.reduce(UInt64(0)) { $0 + ($1.input ?? 0) }
        let output = usages.reduce(UInt64(0)) { $0 + ($1.output ?? 0) }
        let cost = usages.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        return (input, output, cost)
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

    private func loadEvents(id: String, reset: Bool) async {
        do {
            let chunk = try await Bridge.chatEvents(id: id, offset: reset ? 0 : offset)
            if reset {
                events = chunk.events
            } else {
                events.append(contentsOf: chunk.events)
            }
            offset = chunk.nextOffset
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadApprovals(id: String) async {
        do {
            approvals = try await Bridge.chatApprovals(id: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace(_ chat: ChatConversation) {
        selected = chat
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
                items.append(
                    ChatDisplayItem(
                        id: "failed-\(event.atMs ?? 0)-\(items.count)",
                        kind: .failed(agent.text ?? "The turn failed")
                    )
                )
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
