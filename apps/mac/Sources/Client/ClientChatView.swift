// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import SwiftUI

@MainActor @Observable
private final class ClientChatModel {
    var chats: [ChatConversation] = []
    var chat: ChatConversation?
    var events: [ChatTimelineEvent] = []
    var offset: UInt64 = 0
    var error: String?

    func load(peer: String, workspaceID: String) async {
        do {
            chats = try await ClientRemote.chats(peer: peer, workspaceID: workspaceID)
            if chat == nil { chat = chats.first }
            if let chat { await eventsFor(peer: peer, id: chat.id, reset: true) }
        } catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func create(peer: String, workspaceID: String) async {
        do { chat = try await ClientRemote.createChat(peer: peer, workspaceID: workspaceID); events = []; offset = 0 }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func send(peer: String, text: String) async {
        guard let chat else { return }
        do { self.chat = try await ClientRemote.sendChat(peer: peer, id: chat.id, text: text); await eventsFor(peer: peer, id: chat.id, reset: false) }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func stop(peer: String) async {
        guard let chat else { return }
        do { try await ClientRemote.stopChat(peer: peer, id: chat.id) }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func poll(peer: String) async {
        guard let chat, chat.running else { return }
        await eventsFor(peer: peer, id: chat.id, reset: false)
        if let current = try? await ClientRemote.chats(peer: peer, workspaceID: chat.workspaceID).first(where: { $0.id == chat.id }) { self.chat = current }
    }

    private func eventsFor(peer: String, id: String, reset: Bool) async {
        do { let chunk = try await ClientRemote.chatEvents(peer: peer, id: id, offset: reset ? 0 : offset); if reset { events = chunk.events } else { events += chunk.events }; offset = chunk.nextOffset }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }
}

struct ClientChatView: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    @State private var model = ClientChatModel()
    @State private var draft = ""

    var body: some View {
        Group {
            if let chat = model.chat {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack { Image(systemName: "sparkles").foregroundStyle(Theme.accent); Text(chat.title).font(Theme.title3.weight(.semibold)); Spacer(); Text(chat.mode == "plan" ? "Plan" : "Execute").font(Theme.caption).foregroundStyle(Theme.accent) }
                            .padding(Theme.Space.m).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        ForEach(model.events) { ClientChatRow(row: $0) }
                    }.padding(Theme.Space.m)
                }
                composer(chat)
            } else {
                ContentUnavailableView("Start a chat", systemImage: "bubble.left.and.bubble.right", description: Text("Ask an agent to help with (folderName)."))
                    .overlay(alignment: .bottom) { Button("New chat") { Task { await model.create(peer: peer, workspaceID: workspaceID) } }.buttonStyle(AccentButtonStyle()).padding(.bottom, Theme.Space.xl) }
            }
        }
        .background(Theme.background)
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(peer: peer, workspaceID: workspaceID) }
        .task(id: model.chat?.id) { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)); await model.poll(peer: peer) } }
        .alert("Chat unavailable", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(model.error ?? "") }
    }

    private func composer(_ chat: ChatConversation) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Ask about (folderName)", text: $draft, axis: .vertical).lineLimit(1...5).padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { if chat.running { Task { await model.stop(peer: peer) } } else { let text = draft; draft = ""; Task { await model.send(peer: peer, text: text) } } } label: { Image(systemName: chat.running ? "stop.fill" : "arrow.up") }
                .buttonStyle(AccentButtonStyle(small: true)).disabled(!chat.running && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(Theme.Space.m)
    }
}

private struct ClientChatRow: View {
    let row: ChatTimelineEvent
    var body: some View {
        if row.kind == "user" { HStack { Spacer(); Text(row.text ?? "").padding(Theme.Space.m).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous)) } }
        else if let event = row.event {
            switch event.kind {
            case "text": Text(event.delta ?? "").frame(maxWidth: .infinity, alignment: .leading)
            case "toolStart": Label([event.verb, event.target].compactMap { $0 }.joined(separator: " "), systemImage: "hammer").font(Theme.callout).padding(Theme.Space.s).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            case "edit": Label("\(event.path ?? "File")  +\(event.added ?? 0)  −\(event.removed ?? 0)", systemImage: "pencil.line").foregroundStyle(Theme.accent)
            case "failed": Label(event.text ?? "The turn failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            default: EmptyView()
            }
        }
    }
}
#endif
