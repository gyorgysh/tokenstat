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
        for id in 0..<8 { cache.store([message(id)], for: "\(id)", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) }) }
        _ = cache.messages(for: "0")
        cache.store([message(8)], for: "8", cost: { $0.text.utf8.count + $0.id.utf8.count + ($0.backend?.utf8.count ?? 0) })
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
