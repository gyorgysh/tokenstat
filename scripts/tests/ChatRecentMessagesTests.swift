// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatRecentMessages.swift.
import Foundation

private struct ChatRecentMessage: Equatable {
    let id: String
    let text: String
    let backend: String?
    let isUser: Bool
}

@main enum ChatRecentMessagesTests {
    static func main() {
        func message(_ id: Int, text: String = "hello") -> ChatRecentMessage {
            ChatRecentMessage(id: "m\(id)", text: text, backend: "codex", isUser: false)
        }
        var cache = ChatRecentMessages<ChatRecentMessage>()
        cache.store((0..<180).map { message($0) }, for: "account|host|folder|chat", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        let tail = cache.messages(for: "account|host|folder|chat")
        precondition(tail.count == 150 && tail.first?.id == "m30" && tail.last?.id == "m179")
        precondition(cache.messages(for: "other-account|host|folder|chat").isEmpty)
        precondition(cache.messages(for: "account|other-host|folder|chat").isEmpty)
        cache.removeAll()
        for id in 0..<10 { cache.store([message(id)], for: "\(id)", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) }) }
        _ = cache.messages(for: "0")
        cache.store([message(10)], for: "10", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        precondition(cache.messages(for: "1").isEmpty)
        precondition(!cache.messages(for: "0").isEmpty)
        cache.store([message(0, text: String(repeating: "🟣", count: ChatRecentMessages<ChatRecentMessage>.byteLimit))], for: "large", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        precondition(cache.messages(for: "large").isEmpty)
        cache.store([message(1, text: String(repeating: "a", count: 450_000)), message(2, text: String(repeating: "b", count: 100_000))], for: "bounded", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        precondition(cache.messages(for: "bounded").map(\.id) == ["m2"])
        cache.store([message(1)], for: "folder|removed", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        cache.store([message(2)], for: "folder|kept", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        cache.store([message(3)], for: "other|kept", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
        cache.retain(["folder|kept"], in: "folder|")
        precondition(cache.messages(for: "folder|removed").isEmpty)
        precondition(!cache.messages(for: "folder|kept").isEmpty)
        precondition(!cache.messages(for: "other|kept").isEmpty)
        cache.removeAll()
        precondition(cache.messages(for: "folder|kept").isEmpty)
        // Ten per project: a second project's chats must not push the first
        // one's out, and an eleventh in one project drops only its oldest.
        let cost: (ChatRecentMessage) -> Int = { $0.text.utf8.count + $0.id.utf8.count }
        var projects = ChatRecentMessages<ChatRecentMessage>()
        for id in 0..<10 { projects.store([message(id)], for: "a|\(id)", cost: cost) }
        for id in 0..<10 { projects.store([message(id)], for: "b|\(id)", cost: cost) }
        precondition((0..<10).allSatisfy { !projects.messages(for: "a|\($0)").isEmpty })
        projects.store([message(10)], for: "a|10", cost: cost)
        precondition(projects.messages(for: "a|0").isEmpty)
        precondition(!projects.messages(for: "a|10").isEmpty)
        precondition((0..<10).allSatisfy { !projects.messages(for: "b|\($0)").isEmpty })
        // Deleting one chat forgets that chat and nothing else.
        projects.remove("a|5")
        precondition(projects.messages(for: "a|5").isEmpty && !projects.messages(for: "b|5").isEmpty)
        precondition(!projects.messages(for: "a|6").isEmpty && !projects.messages(for: "b|6").isEmpty)
        projects.retain([], in: "a|")
        precondition(!projects.contains("a|6") && projects.contains("b|6"))
        // The whole cache still has a ceiling across projects.
        var many = ChatRecentMessages<ChatRecentMessage>()
        for folder in 0..<10 { for id in 0..<10 { many.store([message(id)], for: "f\(folder)|\(id)", cost: cost) } }
        let held = (0..<10).flatMap { folder in (0..<10).map { "f\(folder)|\($0)" } }
            .filter { !many.messages(for: $0).isEmpty }.count
        precondition(held == ChatRecentMessages<ChatRecentMessage>.conversationLimit)
        // A new project's preview must still enter a full cache of opened
        // chats, rather than evicting itself as its only speculative entry.
        var full = ChatRecentMessages<ChatRecentMessage>()
        for folder in 0..<6 {
            for id in 0..<10 { full.store([message(id)], for: "f\(folder)|\(id)", cost: cost) }
        }
        full.store([message(0)], for: "new|0", speculative: true, cost: cost)
        precondition(full.contains("new|0") && !full.contains("f0|0"))

        // When a project is full, speculative copies go first, and checking
        // for a copy does not count as using it.
        var visits = ChatRecentMessages<ChatRecentMessage>()
        visits.store([message(99)], for: "p|opened", cost: cost)
        for id in 0..<12 { visits.store([message(id)], for: "p|\(id)", speculative: true, cost: cost) }
        precondition(!visits.messages(for: "p|opened").isEmpty)

        // Opening a speculative copy promotes it even if the live read
        // has not finished when another warm-up arrives.
        var promoted = ChatRecentMessages<ChatRecentMessage>()
        for id in 0..<10 { promoted.store([message(id)], for: "p|\(id)", speculative: true, cost: cost) }
        _ = promoted.messages(for: "p|0")
        for id in 10..<25 { promoted.store([message(id)], for: "p|\(id)", speculative: true, cost: cost) }
        precondition(promoted.contains("p|0") && !promoted.contains("p|1"))
        // With no speculative copies left, opened conversations still obey
        // the per-project limit and least-recently-used order.
        for id in 25..<35 { promoted.store([message(id)], for: "p|\(id)", cost: cost) }
        precondition(!promoted.contains("p|0") && promoted.contains("p|34"))
        precondition(visits.contains("p|11") && !visits.contains("p|0"))
        _ = visits.contains("p|2")
        visits.store([message(50)], for: "p|50", speculative: true, cost: cost)
        precondition(!visits.contains("p|2"), "contains must not refresh recency")
        // Storing nothing keeps the copy that was there.
        visits.store([], for: "p|opened", cost: cost)
        precondition(!visits.messages(for: "p|opened").isEmpty)

        // Mixed transcript rows must keep their order and identity. Filtering
        // reasoning/errors/tools out is what changed the height on refresh.
        enum Row: Equatable {
            case user(String), reasoning(String), error(String), tool(String), assistant(String)
        }
        var transcript = ChatRecentMessages<Row>()
        let rows: [Row] = [.user("hi"), .reasoning("checking"), .tool("read"),
                           .error("connection lost"), .assistant("hello")]
        transcript.store(rows, for: "chat", cost: { _ in 64 })
        precondition(transcript.messages(for: "chat") == rows)

        print("Recent-message cache: limits, recency, ownership keys, pruning and clearing passed")
    }
}
