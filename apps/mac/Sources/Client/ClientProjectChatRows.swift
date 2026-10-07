// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Only project metadata is polled here. A row does not create a transcript
/// model, load setup, or warm message pages to draw a title.
struct ClientProjectChatRows: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder
    let rowHeight: CGFloat
    let entry: ClientProjectChats.Entry
    let workspaces: ClientWorkspacesModel
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientChatSessions.self) private var readers
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = WorkSessionContext.shared.scope
    @State private var viewer = UUID()
    @State private var pointer = UUID()
    @State private var menu = UUID()

    private var workspaceID: String { ClientRemote.rawWorkspaceID(of: folder) ?? folder.id }
    private var selectedID: String? {
        let shown = navigation.visibleChat
        return shown?.hostIdentity == peer && shown?.workspaceID == workspaceID ? shown?.itemID : nil
    }
    private var window: Range<Int> {
        ChatHistoryWindow.visible(count: entry.chats.count,
            selected: entry.chats.firstIndex { $0.id == selectedID }, expanded: entry.expanded)
    }

    var body: some View {
        Group {
            ForEach(Array(entry.chats[window])) { chat in
                Button { navigation.openChat(folderID: folder.id, chatID: chat.id) } label: {
                    HStack(spacing: Theme.Space.s) {
                        HarnessMark(id: chat.backend, size: 16)
                        Text(chat.title).font(ClientType.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        if chat.running {
                            Image(systemName: "circle.fill")
                                .font(Theme.fixed(6)).foregroundStyle(Theme.accent)
                                .accessibilityLabel(L10n.text("common.running"))
                        }
                    }
                    .padding(.leading, Theme.Space.l)
                    .clientSidebarRowSurface(isSelected: selectedID == chat.id, height: rowHeight)
                }
                .buttonStyle(.plain)
                .clientSidebarRowChrome()
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in entry.interacting(true, owner: viewer) }
                    .onEnded { _ in entry.interacting(false, owner: viewer) })
                .onHover { entry.interacting($0, owner: pointer) }
                .contextMenu {
                    Group {
                        Button(L10n.text("apple.clientchatmenu.rename_chat.26076241"), .edit) { action(.rename, chat: chat) }
                            .disabled(chat.running)
                        Button(L10n.text("apple.clientchatview.delete_chat.93291d9c"), role: .destructive) { action(.delete, chat: chat) }
                    }
                    .onAppear { entry.interacting(true, owner: menu) }
                    .onDisappear { entry.interacting(false, owner: menu) }
                }
            }
            if !entry.loaded {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("apple.clientchatview.chat.460b3a7d")).font(ClientType.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, Theme.Space.l)
                .frame(minHeight: rowHeight, alignment: .leading)
                .clientSidebarRowChrome()
            }
            if entry.expanded || window.count < min(entry.chats.count, ChatHistoryWindow.inlineLimit) {
                Button {
                    entry.expanded.toggle()
                } label: {
                    Text(entry.expanded ? L10n.text("apple.rootview.show_less.94ea9b1d")
                        : L10n.text("apple.rootview.show_0_more.b91c3640", "\(max(0, min(entry.chats.count, ChatHistoryWindow.inlineLimit) - window.count))"))
                        .font(ClientType.caption).foregroundStyle(.secondary)
                        .padding(.leading, Theme.Space.l)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                }
                .buttonStyle(.plain).clientSidebarRowChrome()
            }
            if entry.chats.count > ChatHistoryWindow.inlineLimit || entry.error != nil {
                Button {
                    readers.session(peer: peer, workspace: workspaceID).opened = nil
                    navigation.requestedChat = nil
                    navigation.open(folderID: folder.id, section: .chat)
                } label: {
                    Label(L10n.text("apple.rootview.see_all_chats.e705024a"), systemImage: "bubble.left.and.bubble.right")
                        .font(ClientType.caption).foregroundStyle(.secondary)
                        .padding(.leading, Theme.Space.l)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                }
                .buttonStyle(.plain).clientSidebarRowChrome()
            }
            if entry.error != nil {
                Button(L10n.text("common.retry"), .refresh) { Task { await load(refresh: true) } }
                    .font(ClientType.caption).foregroundStyle(Theme.accent)
                    .padding(.leading, Theme.Space.l)
                    .frame(minHeight: rowHeight)
                    .buttonStyle(.plain).clientSidebarRowChrome()
                    .accessibilityHint(ClientTunnelCopy.display(entry.error ?? "", host: hostName))
            }
        }
        .onAppear { entry.appear(viewer) }
        .onDisappear {
            entry.interacting(false, owner: pointer)
            entry.interacting(false, owner: menu)
            entry.disappear(viewer)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            guard scenePhase == .active else { return }
            Task { await load(refresh: true) }
        }
    }

    private func load(refresh: Bool = false) async {
        let owner = owner
        await entry.load(refresh: refresh, isCurrent: {
            owner != nil && owner == WorkSessionContext.shared.scope && workspaces.connectedKey == peer
        }, read: { try await ClientRemote.chats(peer: peer, workspaceID: workspaceID) })
    }

    private func action(_ kind: ClientProjectChatAction.Kind, chat: ChatConversation) {
        guard let owner, owner == WorkSessionContext.shared.scope else { return }
        navigation.projectChatAction = .init(scope: owner, peer: peer, workspaceID: workspaceID,
            hostName: hostName, chat: chat, kind: kind)
    }
}
#endif
