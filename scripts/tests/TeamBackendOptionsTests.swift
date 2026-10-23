// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

@main struct TeamBackendOptionsTests {
    static func main() throws {
        let ids = ["claude", "codex", "muse", "grok", "cursor", "agy", "opencode", "opencode2"]
        func option(_ id: String, _ label: JSONValue? = nil) -> JSONValue {
            var row: [String: JSONValue] = ["id": .string(id)]
            if let label { row["label"] = label }
            return .object(row)
        }
        func catalog(_ metadata: JSONValue?) throws -> TeamChatCatalog {
            var row: [String: JSONValue] = ["shares": .array([])]
            if let metadata { row["backends"] = metadata }
            return try JSONDecoder().decode(TeamChatCatalog.self, from: JSONEncoder().encode(JSONValue.object(row)))
        }
        let legacy = try catalog(nil), malformedCatalog = try catalog(.string("malformed"))
        precondition(legacy.backends == nil, "Older hosts must not invent local agent choices")
        precondition(malformedCatalog.backends == nil, "Malformed discovery must not break valid shared chats")
        let advertised = try catalog(.array(ids.map { option($0, .string("Publisher \($0)")) })).backends!
        precondition(advertised.map(\.id) == ids && advertised[5].label == "Publisher agy", "The publisher, not a local hardcoded list, owns labels and IDs")
        let malformed: [JSONValue] = [.null, option(""), option("UPPER"), option("slash/name"), option("é"), option(String(repeating: "x", count: 65)),
            option("blank", .string("  ")), option("long", .string(String(repeating: "x", count: 129))), option("wrong", .int(4)),
            option("multiline", .string("Agent\nname")), option("hidden", .string("\u{200b}"))]
        let filtered = TeamBackendOption.read(malformed + [option("claude", .string("First")), option("claude", .string("Duplicate")), option("future-agent_v2")])
        precondition(filtered == [TeamBackendOption(id: "claude", label: "First"), TeamBackendOption(id: "future-agent_v2", label: "future-agent_v2")])
        let bounded = TeamBackendOption.read((0..<1000).map { option("agent-\($0)") })
        precondition(bounded.count == 32 && bounded.last?.id == "agent-31", "Untrusted metadata cannot create an unbounded menu")
        let duplicates = Array(repeating: option("claude"), count: 32) + [option("outside-cap")]
        let invalidPrefix = Array(repeating: JSONValue.null, count: 32) + [option("outside-cap")]
        precondition(TeamBackendOption.read(duplicates).map(\.id) == ["claude"] && TeamBackendOption.read(invalidPrefix).isEmpty,
                     "Invalid or duplicate rows must still spend the inspected metadata budget")
        let cappedCatalog = try catalog(.array(duplicates))
        precondition(cappedCatalog.backends?.map(\.id) == ["claude"])
        print("Team backend catalog: all eight publisher agents, legacy omission, malformed filtering, unique bounded IDs and publisher labels pass")
    }
}
