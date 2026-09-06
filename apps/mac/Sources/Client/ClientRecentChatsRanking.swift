// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// How the phone's Recents row is chosen.
///
/// Unread and approvals used to rank above recency, then the list was cut to
/// five. A conversation you just left disappeared under a pile of older
/// unread replies. The three newest by time stay on top. Five more follow,
/// ranked by what needs a look.
enum ClientRecentChatsRanking {
    static let recentByTime = 3
    static let moreByPriority = 5
    static let windowMs: Int64 = 7 * 24 * 60 * 60 * 1000

    struct Item: Equatable {
        var id: String
        var lastMessageAtMs: Int64
        var running: Bool
        var needsAttention: Bool
        var unread: Bool
    }

    static func visible(from chats: [Item], nowMs: Int64) -> [Item] {
        let cutoff = nowMs - windowMs
        let candidates = chats.filter { chat in
            chat.needsAttention
                || chat.running
                || chat.unread
                || chat.lastMessageAtMs >= cutoff
        }
        let newest = candidates
            .sorted { $0.lastMessageAtMs > $1.lastMessageAtMs }
        let head = Array(newest.prefix(recentByTime))
        let headIDs = Set(head.map(\.id))
        let rest = candidates
            .filter { !headIDs.contains($0.id) }
            .sorted { left, right in
                let leftPriority = priority(of: left)
                let rightPriority = priority(of: right)
                if leftPriority != rightPriority {
                    return leftPriority > rightPriority
                }
                return left.lastMessageAtMs > right.lastMessageAtMs
            }
        return head + Array(rest.prefix(moreByPriority))
    }

    /// Host-owned approvals first, then this device's unread replies, active
    /// work, and finally ordinary recency.
    static func priority(of chat: Item) -> Int {
        if chat.needsAttention { return 3 }
        if chat.unread { return 2 }
        if chat.running { return 1 }
        return 0
    }
}
