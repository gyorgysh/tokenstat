// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation
import SwiftUI

#if !os(macOS)
import UIKit

/// What this particular phone or iPad has opened.
///
/// Read state is device furniture, not host data. Reading a conversation on
/// an iPad must not silently clear the dot on a phone somebody has not looked
/// at yet, and no transcript or receipt needs to leave either device.
@MainActor @Observable
final class ClientChatReadState {
    static let shared = ClientChatReadState()

    private static let defaultsKey = "chat.readReceipts.v1"
    private static let trackingStartedKey = "chat.readTrackingStartedAt.v1"
    private var reads: [String: Int64]
    /// There is no server receipt to migrate when this feature first appears.
    /// Treating every older agent reply as unseen would pin years of history in
    /// Recents, so this device's first use is the honest unread baseline.
    private let trackingStartedAt: Int64

    private init() {
        let defaults = UserDefaults.standard
        reads = defaults
            .data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) }
            ?? [:]
        if let stored = defaults.object(forKey: Self.trackingStartedKey) as? NSNumber,
           stored.int64Value > 0 {
            trackingStartedAt = stored.int64Value
        } else {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            trackingStartedAt = now
            defaults.set(now, forKey: Self.trackingStartedKey)
        }
    }

    func isUnread(peer: String, chat: ChatConversation) -> Bool {
        isUnread(
            peer: peer,
            chatID: chat.id,
            lastMessageAtMs: chat.lastMessageAtMs,
            lastMessageAuthor: chat.lastMessageAuthor
        )
    }

    func isUnread(peer: String, chat: ChatRecentConversation) -> Bool {
        isUnread(
            peer: peer,
            chatID: chat.id,
            lastMessageAtMs: chat.lastMessageAtMs,
            lastMessageAuthor: chat.lastMessageAuthor
        )
    }

    private func isUnread(
        peer: String,
        chatID: String,
        lastMessageAtMs: Int64?,
        lastMessageAuthor: String?
    ) -> Bool {
        guard lastMessageAuthor == "agent", let at = lastMessageAtMs else {
            return false
        }
        let lastRead = reads[key(peer: peer, chatID: chatID), default: trackingStartedAt]
        return max(lastRead, trackingStartedAt) < at
    }

    func markRead(peer: String?, chat: ChatConversation) {
        guard let at = chat.lastMessageAtMs else { return }
        let key = key(peer: peer ?? "local", chatID: chat.id)
        guard reads[key, default: 0] < at else { return }
        reads[key] = at
        if let data = try? JSONEncoder().encode(reads) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func key(peer: String, chatID: String) -> String {
        "\(peer)/\(chatID)"
    }
}

/// The short path back into work, shown below folders on a connected host.
///
/// Five newest fit without pushing sessions off screen; the rest wait behind
/// "Show more" rather than making the page an archive.
struct ClientRecentChatsSection: View {
    let peer: String
    let hostName: String
    let folders: [WorkspaceFolder]
    let chats: [ChatRecentConversation]
    /// When set and there is a folder to start in, a "New chat" button sits
    /// beside the title. Chats live inside folders, so starting one means
    /// picking the folder first; the caller owns that sheet.
    var onNewChat: (() -> Void)? = nil

    /// How many rows show before "Show more".
    private static let collapsedLimit = 5

    @State private var expanded = false

    private var receipts: ClientChatReadState { .shared }

    /// Three newest by time, then five more by what needs a look. Unread used
    /// to take every slot, so a chat you just left vanished under older dots.
    private var visible: [ChatRecentConversation] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ranked = ClientRecentChatsRanking.visible(
            from: chats.map { chat in
                ClientRecentChatsRanking.Item(
                    id: chat.id,
                    lastMessageAtMs: chat.lastMessageAtMs ?? 0,
                    running: chat.running,
                    needsAttention: chat.needsAttention,
                    unread: receipts.isUnread(peer: peer, chat: chat)
                )
            },
            nowMs: nowMs
        )
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return ranked.compactMap { byID[$0.id] }
    }

    private var shown: [ChatRecentConversation] {
        expanded ? visible : Array(visible.prefix(Self.collapsedLimit))
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .center) {
                    ClientSectionTitle(title: "Recent chats", mark: "mark_activity")
                    Spacer(minLength: Theme.Space.s)
                    if onNewChat != nil, !folders.isEmpty {
                        Button("New chat", .create) { onNewChat?() }
                            .font(ClientType.caption.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)

                ForEach(shown) { chat in
                    NavigationLink {
                        ClientRecentChatView(
                            peer: peer,
                            workspaceID: chat.workspaceID,
                            folderName: folderName(for: chat.workspaceID),
                            hostName: hostName,
                            chatID: chat.id
                        )
                    } label: {
                        ClientRecentChatRow(
                            chat: chat,
                            folderName: folderName(for: chat.workspaceID),
                            unread: receipts.isUnread(peer: peer, chat: chat)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if visible.count > Self.collapsedLimit {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(
                            expanded
                                ? "Show less"
                                : "Show more (\(visible.count - Self.collapsedLimit) more)",
                            systemImage: expanded ? "chevron.up" : "chevron.down"
                        )
                        .font(ClientType.caption.weight(.semibold))
                    }
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
                    .accessibilityHint(expanded
                        ? "Shows only the five newest chats"
                        : "Shows every recent chat")
                }
            }
        }
    }

    private func folderName(for workspaceID: String) -> String {
        folders.first {
            (ClientRemote.rawWorkspaceID(of: $0) ?? $0.id) == workspaceID
        }?.name ?? "Workspace"
    }
}

private struct ClientRecentChatRow: View {
    let chat: ChatRecentConversation
    let folderName: String
    let unread: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ZStack(alignment: .topTrailing) {
                HarnessMark(id: chat.backend, size: 28)
                if unread || chat.needsAttention {
                    Circle()
                        .fill(chat.needsAttention ? Theme.warning : Theme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                        .offset(x: 2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title)
                    .font(ClientType.label.weight(unread || chat.needsAttention ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(folderName)
                    if let at = chat.lastMessageAtMs {
                        Text("·")
                        Text(RelativeClock.phrase(
                            for: Date(timeIntervalSince1970: Double(at) / 1000),
                            style: .abbreviated
                        ))
                    }
                    if chat.needsAttention {
                        Text("· Needs approval")
                            .foregroundStyle(Theme.warning)
                    } else if chat.running {
                        Text("· Working")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: ActionIcon.next.symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if chat.needsAttention, unread { return "Needs approval, unread" }
        if chat.needsAttention { return "Needs approval" }
        if unread { return "Unread" }
        return ""
    }
}

/// Owns the folder model but presents the exact selected thread, so Back
/// returns to Workspaces rather than stopping at the folder's chat list.
struct ClientRecentChatView: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    let hostName: String
    let chatID: String

    @State private var model = ChatModel()
    @State private var loaded = false
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ClientPlaceAvailability(peer: peer, hostName: hostName) {
            thread.task { await load() }
        }
    }

    private var thread: some View {
        Group {
            if model.chats.contains(where: { $0.id == chatID }) {
                ClientChatThread(
                    model: model,
                    chatID: chatID,
                    folderName: folderName,
                    hostName: hostName
                )
            } else if let error = model.error {
                ClientErrorCard(message: ClientTunnelCopy.display(error, host: hostName)) {
                    Task { await load() }
                }
                .padding(Theme.Space.m)
            } else if loaded {
                ClientEmptyState(
                    kind: .nothingYet,
                    title: "This chat is gone",
                    message: "It may have been deleted on \(hostName).",
                    art: .chat(seed: model.defaultFaceSeed)
                )
                .padding(Theme.Space.m)
            } else {
                ClientWireframe.Rows(count: 5)
                    .padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
        // Same hide as a folder conversation, but only while the thread is
        // actually on screen. The "gone" state has no composer to make room
        // for. Back pops this whole screen to Workspaces, so restore has to
        // run on the way out.
        .clientTabBarHidden(!loaded || model.chats.contains(where: { $0.id == chatID }))
        .onAppear {
            // The notification cover is `presentedChat`. Writing here would
            // hide the folder thread sitting under it.
            if navigation.presentedChat == nil {
                navigation.visibleChatID = chatID
            }
        }
        .onDisappear {
            guard scenePhase == .active,
                  UIApplication.shared.applicationState == .active
            else { return }
            if navigation.presentedChat == nil, navigation.visibleChatID == chatID {
                navigation.visibleChatID = nil
            }
        }
    }

    private func load() async {
        guard !peer.isEmpty, !workspaceID.isEmpty, !chatID.isEmpty else {
            loaded = true
            return
        }
        await model.load(workspaceID: workspaceID, peer: peer, selectFirst: false)
        loaded = true
    }
}

/// Pick one of a host's folders to start something in.
///
/// Chats and sessions live inside folders, so a host-level "New chat" or
/// "New session" button cannot act until it knows which folder. This sheet is
/// that question, shared by both host screens. The caller navigates into the
/// folder's section, where the launch tiles and the chat composer already are.
struct ClientFolderChooserSheet: View {
    let hostName: String
    let folders: [WorkspaceFolder]
    /// What starting means once a folder is picked, in the sheet's own words.
    let title: String
    let onChoose: (WorkspaceFolder) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(folders) { folder in
                        Button {
                            onChoose(folder)
                            dismiss()
                        } label: {
                            ClientFolderRow(folder: folder)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

#endif
