// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

@MainActor @Observable
final class ChatModel {
    var chats: [ChatConversation] = []
    var selected: ChatConversation?
    var events: [ChatTimelineEvent] = []
    var offset: UInt64 = 0
    var isLoading = false
    var error: String?

    func load(workspaceID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            chats = try await Bridge.chats(workspaceID: workspaceID)
            if selected == nil { selected = chats.first }
            if let selected { await loadEvents(id: selected.id, reset: true) }
        } catch { self.error = error.localizedDescription }
    }

    func create(workspaceID: String, backend: String = "claude", mode: String = "plan") async {
        do {
            let chat = try await Bridge.createChat(workspaceID: workspaceID, backend: backend, mode: mode)
            chats.insert(chat, at: 0)
            selected = chat
            events = []
            offset = 0
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String) async {
        guard let selected else { return }
        do {
            let updated = try await Bridge.sendChat(id: selected.id, text: text)
            replace(updated)
            await loadEvents(id: updated.id, reset: false)
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        guard let selected else { return }
        do {
            try await Bridge.stopChat(id: selected.id)
        } catch { self.error = error.localizedDescription }
    }

    func poll() async {
        guard let selected, selected.running else { return }
        await loadEvents(id: selected.id, reset: false)
        do { replace(try await Bridge.chats(workspaceID: selected.workspaceID).first(where: { $0.id == selected.id }) ?? selected) } catch {}
    }

    private func loadEvents(id: String, reset: Bool) async {
        do {
            let chunk = try await Bridge.chatEvents(id: id, offset: reset ? 0 : offset)
            if reset { events = chunk.events } else { events.append(contentsOf: chunk.events) }
            offset = chunk.nextOffset
        } catch { self.error = error.localizedDescription }
    }

    private func replace(_ chat: ChatConversation) {
        selected = chat
        if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = chat }
    }
}

struct ChatView: View {
    let workspaceID: String
    var workspaceName: String? = nil
    @State private var model = ChatModel()
    @State private var draft = ""
    @State private var showingSetup = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar(scope: workspaceName.map { ScopeChip(label: $0, symbol: "folder.fill") }) {
                ToolbarIconButton(systemImage: "plus", help: "New chat") { showingSetup = true }
            }
            #endif
            if let chat = model.selected {
                transcript(chat)
                composer(chat)
            } else {
                empty
            }
        }
        .background(Theme.background)
        .task(id: workspaceID) { await model.load(workspaceID: workspaceID) }
        .task(id: model.selected?.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await model.poll()
            }
        }
        .alert("Chat unavailable", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showingSetup) {
            ChatSetupSheet { backend, mode in
                showingSetup = false
                Task { await model.create(workspaceID: workspaceID, backend: backend, mode: mode) }
            }
        }
    }

    private func transcript(_ chat: ChatConversation) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                setup(chat)
                ForEach(model.events) { row in ChatEventRow(row: row) }
                if chat.running { HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text("Working").font(Theme.caption).foregroundStyle(.secondary) }.padding(.horizontal, Theme.Space.l) }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.vertical, Theme.Space.xl)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func setup(_ chat: ChatConversation) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text(chat.title).font(Theme.title3.weight(.semibold))
            chip(chat.backend.capitalized)
            if chat.mode == "plan" { chip("Plan") }
            Spacer()
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1) }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.accentSoft, in: Capsule())
    }

    private func composer(_ chat: ChatConversation) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Ask about \(workspaceName ?? "this folder")", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1) }
            if chat.running {
                Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 34, height: 34) }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            } else {
                Button { let text = draft; draft = ""; Task { await model.send(text) } } label: { Image(systemName: "arrow.up").frame(width: 34, height: 34) }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.background)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            ChatScene(reduceMotion: false)
            Text("Start a chat").font(Theme.title2.weight(.semibold))
            Text("Ask an agent to explore, plan, or work in this folder.").font(Theme.callout).foregroundStyle(.secondary)
            Button("New chat") { showingSetup = true }.buttonStyle(AccentButtonStyle())
            Spacer()
        }
    }
}

private struct ChatSetupSheet: View {
    let create: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backend = "claude"
    @State private var mode = "plan"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("New chat").font(Theme.title2.weight(.semibold))
                Text("Choose how this conversation should begin. You can refine its settings before the first message.")
                    .font(Theme.callout).foregroundStyle(.secondary)
            }
            Picker("Agent", selection: $backend) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
                Text("Grok").tag("grok")
                Text("Cursor").tag("cursor")
                Text("Antigravity").tag("agy")
                Text("OpenCode").tag("opencode")
            }
            Picker("Starting mode", selection: $mode) {
                Text("Plan — explore before changing work").tag("plan")
                Text("Execute — work directly in the folder").tag("execute")
            }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }; Button("Create chat") { create(backend, mode) }.buttonStyle(AccentButtonStyle()) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
    }
}

private struct ChatEventRow: View {
    let row: ChatTimelineEvent
    var body: some View {
        if row.kind == "user" {
            HStack { Spacer(minLength: 48); Text(row.text ?? "").font(Theme.body).padding(Theme.Space.m).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        } else if let event = row.event {
            switch event.kind {
            case "text": Text(event.delta ?? "").font(Theme.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            case "thinking": Label(event.delta ?? "Thinking", systemImage: "brain").font(Theme.caption).foregroundStyle(.secondary).padding(.vertical, 2)
            case "toolStart": Label([event.verb, event.target].compactMap { $0 }.joined(separator: " "), systemImage: "hammer").font(Theme.callout).padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            case "edit": Label("\(event.path ?? "File")  +\(event.added ?? 0)  −\(event.removed ?? 0)", systemImage: "pencil.line").font(Theme.callout).foregroundStyle(Theme.accent)
            case "failed": Label(event.text ?? "The turn failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            case "usage": Text("\(event.input ?? 0) in · \(event.output ?? 0) out").font(Theme.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }
}
