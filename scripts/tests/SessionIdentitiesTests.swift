// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SessionIdentities.swift.
import Foundation

@main struct SessionIdentitiesTests {
    static func main() throws {
        let wire = Data(#"{"entries":[{"backend":"claude","id":"old-native","status":"historical","sourceConversationId":"chat-origin","firstSeenAtMs":1,"lastSeenAtMs":2},{"backend":"claude","id":"current-native","status":"current","sourceConversationId":"chat-current","lastSeenAtMs":10},{"backend":"codex","id":"saved-native","status":"saved","lastSeenAtMs":9},{"backend":"claude","id":"current-native","status":"historical","sourceConversationId":"chat-fork-source"},{"backend":"future-agent","id":"future-native","status":"future-status"},null,{"id":"malformed-no-backend"}],"total":80,"truncated":true,"archivePath":"/local/history.json","transcriptPath":"/local/transcript.jsonl"}"#.utf8)
        let report = try JSONDecoder().decode(SessionIdentities.self, from: wire)
        precondition(report.total == 80 && report.truncated && report.entries.count == 7)
        let rows = SessionIdentityPresentation.entries(localID: "chat-current", kind: .conversation, sessions: report)
        precondition(rows.first?.kind == .conversation && rows.first?.value == "chat-current")
        precondition(rows.filter { $0.kind == .current }.map(\.value) == ["current-native"], "Only attested current status may claim current")
        precondition(rows.first { $0.value == "saved-native" }?.kind == .saved, "Stored resume candidates stay distinct from historical identifiers")
        precondition(rows.first { $0.value == "old-native" }?.kind == .historical)
        precondition(rows.first { $0.value == "future-native" }?.kind == .historical, "Unknown statuses cannot imply resumability")
        precondition(rows.filter { $0.value == "current-native" }.count == 1, "A historical duplicate cannot override the current entry")
        precondition(Set(rows.filter { $0.kind == .sourceConversation }.map(\.value)) == ["chat-origin", "chat-fork-source"], "Distinct source conversation IDs survive native-ID deduplication")
        precondition(!rows.contains { $0.value == "malformed-no-backend" })
        let roundtrip = try JSONDecoder().decode(SessionIdentities.self, from: JSONEncoder().encode(report))
        precondition(roundtrip == report)
        for malformed in ["null", "[]", "false", #"{"entries":[null,false,{},"bad"],"total":"bad","truncated":"bad"}"#] {
            let unknown = try JSONDecoder().decode(SessionIdentities.self, from: Data(malformed.utf8))
            let fallback = SessionIdentityPresentation.entries(localID: "chat", kind: .conversation, sessions: unknown)
            precondition(fallback.count == 1 && fallback[0].value == "chat", "Malformed optional telemetry must leave the host conversation readable")
        }
        let old = SessionIdentityPresentation.entries(localID: "pty-42", kind: .terminal, sessions: nil)
        precondition(old.count == 1 && old[0].kind == .terminal && old[0].value == "pty-42")
        precondition(SessionIdentityPresentation.entries(localID: "pending-ui-placeholder", kind: .terminal, sessions: nil).isEmpty,
                     "A local placeholder must never masquerade as a host terminal ID")
        precondition(SessionIdentityPresentation.entries(localID: "id\ncommand", kind: .terminal, sessions: nil).isEmpty,
                     "Multiline metadata cannot become a copyable session identifier")
        print("Session identities: current/saved/history, provenance, deduplication, old-host fallback, malformed optional records and real PTY IDs passed")
    }
}
