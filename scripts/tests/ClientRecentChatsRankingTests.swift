// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientRecentChatsRanking.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ClientRecentChatsRankingTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() {
        let now: Int64 = 1_700_000_000_000
        func ago(_ minutes: Int64, unread: Bool = false, attention: Bool = false, running: Bool = false, id: String? = nil) -> ClientRecentChatsRanking.Item {
            ClientRecentChatsRanking.Item(
                id: id ?? "m\(minutes)",
                lastMessageAtMs: now - minutes * 60_000,
                running: running,
                needsAttention: attention,
                unread: unread
            )
        }

        let buried = ClientRecentChatsRanking.visible(
            from: [
                ago(1, id: "just-now"),
                ago(2, id: "a-minute-ago"),
                ago(3, id: "two-minutes"),
                ago(10, unread: true, id: "unread-a"),
                ago(20, unread: true, id: "unread-b"),
                ago(30, unread: true, id: "unread-c"),
                ago(40, unread: true, id: "unread-d"),
                ago(50, unread: true, id: "unread-e"),
                ago(60, unread: true, id: "unread-f"),
            ],
            nowMs: now
        )
        require(
            buried.map(\.id) == [
                "just-now", "a-minute-ago", "two-minutes",
                "unread-a", "unread-b", "unread-c", "unread-d", "unread-e",
            ],
            "Three newest by time, then five unread. The just-used chat stays on top."
        )

        let attention = ClientRecentChatsRanking.visible(
            from: [
                ago(1, id: "fresh"),
                ago(2, id: "fresh-2"),
                ago(3, id: "fresh-3"),
                ago(15, unread: true, id: "unread"),
                ago(25, attention: true, id: "approve"),
                ago(35, running: true, id: "running"),
            ],
            nowMs: now
        )
        require(
            Array(attention.dropFirst(3)).map(\.id) == ["approve", "unread", "running"],
            "After the three newest, approvals outrank unread, then running work."
        )

        let week: Int64 = 8 * 24 * 60 * 60 * 1000 / 60_000
        let cutoff = ClientRecentChatsRanking.visible(
            from: [
                ago(week, id: "old-read"),
                ago(week, unread: true, id: "old-unread"),
            ],
            nowMs: now
        )
        require(
            cutoff.map(\.id) == ["old-unread"],
            "A week-old read chat drops. Unread survives the window."
        )

        print("ClientRecentChatsRankingTests passed")
    }
}
