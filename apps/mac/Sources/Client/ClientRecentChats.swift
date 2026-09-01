// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation
import SwiftUI

#if !os(macOS)

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

/// The short path back into work, shown above folders on a connected host.
struct ClientRecentChatsSection: View {
    let peer: String
    let hostName: String
    let folders: [WorkspaceFolder]
    let chats: [ChatRecentConversation]

    private var receipts: ClientChatReadState { .shared }

    /// A week is recent enough to be useful without turning this into another
    /// permanent chat list. Unread replies survive the window, capped by the
    /// same five rows, so a reply cannot disappear merely because life was busy.
    private var visible: [ChatRecentConversation] {
        let cutoff = Int64(Date().addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
        let candidates = chats.filter { chat in
            chat.needsAttention
                || chat.running
                || receipts.isUnread(peer: peer, chat: chat)
                || (chat.lastMessageAtMs ?? 0) >= cutoff
        }
        return Array(candidates.sorted { left, right in
            let leftPriority = priority(of: left)
            let rightPriority = priority(of: right)
            if leftPriority != rightPriority {
                return leftPriority > rightPriority
            }
            return (left.lastMessageAtMs ?? 0) > (right.lastMessageAtMs ?? 0)
        }.prefix(5))
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Recent chats", mark: "mark_activity")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)

                ForEach(visible) { chat in
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
            }
        }
    }

    private func folderName(for workspaceID: String) -> String {
        folders.first {
            (ClientRemote.rawWorkspaceID(of: $0) ?? $0.id) == workspaceID
        }?.name ?? "Workspace"
    }

    /// Host-owned approvals first, then this device's unread replies, active
    /// work, and finally ordinary recency. Keeping unread local is deliberate:
    /// opening a chat on one device must not clear it on another.
    private func priority(of chat: ChatRecentConversation) -> Int {
        if chat.needsAttention { return 3 }
        if receipts.isUnread(peer: peer, chat: chat) { return 2 }
        if chat.running { return 1 }
        return 0
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

    var body: some View {
        Group {
            if model.chats.contains(where: { $0.id == chatID }) {
                ClientChatThread(
                    model: model,
                    chatID: chatID,
                    folderName: folderName,
                    hostName: hostName
                )
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
        .task {
            await model.load(workspaceID: workspaceID, peer: peer, selectFirst: false)
            loaded = true
        }
    }
}

#endif
