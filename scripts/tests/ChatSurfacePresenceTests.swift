// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatSurfacePresence.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ChatSurfacePresenceTests {
    static func main() {
        var presence = ChatSurfacePresence()
        var previous = UUID()
        presence.update(owner: previous, conversation: "chat", active: true)
        for _ in 0..<30 {
            let successor = UUID()
            presence.update(owner: successor, conversation: "chat", active: true)
            presence.remove(owner: previous)
            precondition(presence.isWatching("chat") && presence.visibleConversation == "chat",
                "late teardown cannot clear a fold successor")
            previous = successor
        }
        let anotherScene = UUID()
        presence.update(owner: anotherScene, conversation: "other-chat", active: true)
        precondition(presence.isWatching("chat") && presence.isWatching("other-chat"))
        presence.update(owner: previous, conversation: "chat", active: false)
        precondition(!presence.isWatching("chat") && presence.isWatching("other-chat"),
            "backgrounding one scene must not change another")
        presence.remove(owner: anotherScene)
        precondition(presence.visibleConversation == nil)
        presence.update(owner: previous, conversation: "chat", active: true)
        precondition(presence.isWatching("chat"), "foregrounding restores its own claim")
        presence.update(owner: previous, conversation: nil, active: true)
        precondition(!presence.isWatching("chat") && presence.visibleConversation == nil)
        presence.update(owner: UUID(), conversation: "", active: true)
        precondition(presence.visibleConversation == nil)
        print("ChatSurfacePresenceTests passed: 30 teardown races and independent scene activity.")
    }
}
