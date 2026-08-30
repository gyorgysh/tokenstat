// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
private final class ClientChatModel {
    var chats: [ChatConversation] = []
    var chat: ChatConversation?
    var events: [ChatTimelineEvent] = []
    var approvals: [ChatApproval] = []
    var offset: UInt64 = 0
    var attachments: [ChatAttachment] = []
    var backends: [ChatBackend] = []
    var error: String?

    func load(peer: String, workspaceID: String) async {
        do {
            backends = try await ClientRemote.chatBackends(peer: peer)
            chats = try await ClientRemote.chats(peer: peer, workspaceID: workspaceID)
            if chat == nil { chat = chats.first }
            if let chat {
                await eventsFor(peer: peer, id: chat.id, reset: true)
                await approvalsFor(peer: peer, id: chat.id)
            }
        } catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func create(peer: String, workspaceID: String) async {
        do { chat = try await ClientRemote.createChat(peer: peer, workspaceID: workspaceID); events = []; offset = 0 }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func send(peer: String, text: String) async {
        guard let chat else { return }
        do { self.chat = try await ClientRemote.sendChat(peer: peer, id: chat.id, text: text, attachmentIDs: attachments.map(\.id)); attachments = []; await eventsFor(peer: peer, id: chat.id, reset: false) }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func attach(peer: String, file: URL) async {
        guard let chat else { return }
        do { attachments.append(try await ClientRemote.attachToChat(peer: peer, id: chat.id, file: file)) }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func stop(peer: String) async {
        guard let chat else { return }
        do { try await ClientRemote.stopChat(peer: peer, id: chat.id) }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func resolve(peer: String, approval: ChatApproval, choice: String) async {
        do {
            _ = try await ClientRemote.resolveChatApproval(peer: peer, id: approval.id, choice: choice)
            await approvalsFor(peer: peer, id: approval.conversationID)
        } catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    func poll(peer: String) async {
        guard let chat, chat.running else { return }
        await eventsFor(peer: peer, id: chat.id, reset: false)
        await approvalsFor(peer: peer, id: chat.id)
        if let current = try? await ClientRemote.chats(peer: peer, workspaceID: chat.workspaceID).first(where: { $0.id == chat.id }) { self.chat = current }
    }

    private func eventsFor(peer: String, id: String, reset: Bool) async {
        do { let chunk = try await ClientRemote.chatEvents(peer: peer, id: id, offset: reset ? 0 : offset); if reset { events = chunk.events } else { events += chunk.events }; offset = chunk.nextOffset }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }

    private func approvalsFor(peer: String, id: String) async {
        do { approvals = try await ClientRemote.chatApprovals(peer: peer, id: id) }
        catch { self.error = ClientTunnelCopy.display(error.localizedDescription, host: nil) }
    }
}

struct ClientChatView: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    @State private var model = ClientChatModel()
    @State private var draft = ""
    @State private var importingAttachment = false

    var body: some View {
        Group {
            if let chat = model.chat {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                            Text(chat.title).font(Theme.title3.weight(.semibold))
                            Spacer()
                            Text(chat.mode == "plan" ? "Plan" : "Execute").font(Theme.caption).foregroundStyle(Theme.accent)
                            Text(gateLabel(chat)).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.accentSoft, in: Capsule())
                        }
                            .padding(Theme.Space.m).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        ForEach(model.events) { row in
                            ClientChatRow(
                                row: row,
                                isPending: row.approval.map { approval in model.approvals.contains(where: { $0.id == approval.id }) } ?? false,
                                resolve: { approval, choice in Task { await model.resolve(peer: peer, approval: approval, choice: choice) } }
                            )
                        }
                    }.padding(Theme.Space.m)
                }
                composer(chat)
            } else {
                ContentUnavailableView("Start a chat", systemImage: "bubble.left.and.bubble.right", description: Text("Ask an agent to help with \(folderName)."))
                    .overlay(alignment: .bottom) { Button("New chat", .create) { Task { await model.create(peer: peer, workspaceID: workspaceID) } }.buttonStyle(AccentButtonStyle()).padding(.bottom, Theme.Space.xl) }
            }
        }
        .background(Theme.background)
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(peer: peer, workspaceID: workspaceID) }
        .task(id: model.chat?.id) { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)); await model.poll(peer: peer) } }
        .alert("Chat unavailable", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(model.error ?? "") }
    }

    private func gateLabel(_ chat: ChatConversation) -> String {
        switch model.backends.first(where: { $0.id == chat.backend })?.gateTier {
        case "full": return "Approvals"
        case "rules": return "Rules"
        case "bypassOnly": return "Bypass only"
        default: return "Checking"
        }
    }

    private func composer(_ chat: ChatConversation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !model.attachments.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(model.attachments) { attachment in
                        Label(attachment.name, systemImage: "paperclip").font(Theme.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 5).background(Theme.panel, in: Capsule())
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                Button { importingAttachment = true } label: { Image(systemName: "paperclip") }.buttonStyle(SecondaryButtonStyle(small: true))
                TextField("Ask about \(folderName)", text: $draft, axis: .vertical).lineLimit(1...5).padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { if chat.running { Task { await model.stop(peer: peer) } } else { let text = draft; draft = ""; Task { await model.send(peer: peer, text: text) } } } label: { Image(systemName: chat.running ? "stop.fill" : "arrow.up") }
                .buttonStyle(AccentButtonStyle(small: true)).disabled(!chat.running && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(Theme.Space.m)
        .fileImporter(isPresented: $importingAttachment, allowedContentTypes: [.image, .pdf, .plainText, .sourceCode]) {
            if case let .success(file) = $0 { Task { await model.attach(peer: peer, file: file) } }
        }
    }
}

private struct ClientChatRow: View {
    let row: ChatTimelineEvent
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void
    var body: some View {
        if row.kind == "user" { HStack { Spacer(); Text(row.text ?? "").padding(Theme.Space.m).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous)) } }
        else if let approval = row.approval {
            ClientChatApprovalCard(approval: approval, isPending: isPending, resolve: resolve)
        }
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

private struct ClientChatApprovalCard: View {
    let approval: ChatApproval
    let isPending: Bool
    let resolve: (ChatApproval, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(isPending ? "Permission needed" : "Permission answered", systemImage: "hand.raised.fill")
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(approval.verb).font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
            }
            Text(approval.preview)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(4)
                .textSelection(.enabled)
            if isPending {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) { actions }
                    VStack(alignment: .leading, spacing: Theme.Space.s) { actions }
                }
            } else {
                Text("This request is no longer waiting.")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isPending ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1) }
    }

    @ViewBuilder private var actions: some View {
        Button("Allow", .approve) { resolve(approval, "allow") }
            .buttonStyle(SecondaryButtonStyle(small: true))
        Button("Always allow", .approve) { resolve(approval, "allowAlways") }
            .buttonStyle(AccentButtonStyle(small: true))
        Button("Deny", .dismiss, role: .destructive) { resolve(approval, "deny") }
            .buttonStyle(SecondaryButtonStyle(small: true))
    }
}
#endif
