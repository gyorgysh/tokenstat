// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
enum L10n { static func text(_ key: String) -> String { key } }
// Only the saved-copy initializer's signature needs this inert reference.
struct WorkReference { var workspaceID: String; var itemID: String? }
/* SOURCE_RECORDS */
/* SOURCE_PAGING */

@main enum ReaderReference {
    static func decoded<T: Codable>(_ type: T.Type, _ value: Any) -> [String: Any] {
        do {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            let decoded = try JSONDecoder().decode(type, from: bytes)
            let encoded = try JSONEncoder().encode(decoded)
            return ["ok": true, "value": try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])]
        } catch { return ["ok": false] }
    }
    @MainActor static func main() async throws {
        let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
        let wire = (input["wire"] as! [[String: Any]]).map { record -> [String: Any] in
            let value = record["value"]!
            switch record["type"] as! String {
            case "conversation": return decoded(ChatConversation.self, value)
            case "event": return decoded(ChatTimelineEvent.self, value)
            case "agent": return decoded(ChatAgentEvent.self, value)
            case "page": return decoded(ChatEventPage.self, value)
            case "chunk": return decoded(ChatEventChunk.self, value)
            default: fatalError("unknown type")
            }
        }
        let caches = (input["caches"] as! [[String: Any]]).map { trace -> [[String: Any]] in
            var cache = ChatRecentMessages<[String: Any]>()
            return (trace["actions"] as! [[String: Any]]).map { action in
                let key = action["key"] as? String ?? ""
                var result: Any = NSNull()
                switch action["op"] as! String {
                case "store": cache.store(action["rows"] as! [[String: Any]], for: key, speculative: action["speculative"] as? Bool ?? false) { ($0["cost"] as! NSNumber).intValue }
                case "messages": result = cache.messages(for: key)
                case "peek": result = cache.peek(key)
                case "remove": cache.remove(key)
                case "retain": cache.retain(Set(action["keys"] as! [String]), in: action["folder"] as! String)
                case "clear": cache.removeAll()
                default: fatalError("unknown operation")
                }
                return ["result": result, "entries": (trace["keys"] as! [String]).map { ["key": $0, "contains": cache.contains($0), "rows": cache.peek($0)] }]
            }
        }
        let revisions: [Any] = (input["revisions"] as! [[Any]]).map { row in
            func revision(_ index: Int) -> UInt64? { (row[index] as? NSNumber)?.uint64Value }
            return ChatSendContext.afterOwnEdit(revision(0), previous: revision(1), updated: revision(2)) as Any? ?? NSNull()
        }
        let windows = await pagingReference(input["windows"] as! [[String: Any]])
        let output: [String: Any] = ["wire": wire, "caches": caches, "revisions": revisions, "windows": windows,
            "paging": [ChatPaging.openPageEvents, ChatPaging.pageEvents, ChatPaging.previewPageEvents, ChatPaging.hostPageEventsMax]]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
