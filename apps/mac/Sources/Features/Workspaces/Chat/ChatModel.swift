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
            await loadEvents(id: updated.id, reset: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func attach(_ file: URL) async {
        guard let selected else { return }
        do {
            attachments.append(try await Bridge.attachToChat(id: selected.id, file: file))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
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
