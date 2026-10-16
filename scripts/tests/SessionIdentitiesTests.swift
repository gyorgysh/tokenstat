// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SessionIdentities.swift.
import Foundation

@main struct SessionIdentitiesTests {
    static func main() throws {
        let wire = Data(#"{"entries":[{"backend":"claude","id":"11111111-1111-4111-8111-111111111111","status":"historical","sourceConversationId":"chat-origin","firstSeenAtMs":1,"lastSeenAtMs":2},{"backend":"claude","id":"22222222-2222-4222-8222-222222222222","status":"current","sourceConversationId":"chat-current","lastSeenAtMs":10},{"backend":"codex","id":"33333333-3333-4333-8333-333333333333","status":"saved","lastSeenAtMs":9},{"backend":"claude","id":"22222222-2222-4222-8222-222222222222","status":"historical","sourceConversationId":"chat-fork-source"},{"backend":"future-agent","id":"44444444-4444-4444-8444-444444444444","status":"future-status"},null,{"id":"malformed-no-backend"}],"total":80,"truncated":true,"archivePath":"/local/history.json","transcriptPath":"/local/transcript.jsonl"}"#.utf8)
        let report = try JSONDecoder().decode(SessionIdentities.self, from: wire)
        precondition(report.total == 80 && report.truncated && report.entries.count == 7)
        let rows = SessionIdentityPresentation.entries(localID: "chat-current", kind: .conversation, sessions: report)
        precondition(rows.first?.kind == .conversation && rows.first?.value == "chat-current")
        precondition(rows.filter { $0.kind == .current }.map(\.value) == ["22222222-2222-4222-8222-222222222222"], "Only attested current status may claim current")
        precondition(rows.first { $0.value == "33333333-3333-4333-8333-333333333333" }?.kind == .saved, "Stored resume candidates stay distinct from historical identifiers")
        precondition(rows.first { $0.value == "11111111-1111-4111-8111-111111111111" }?.kind == .historical)
        precondition(!rows.contains { $0.value == "44444444-4444-4444-8444-444444444444" }, "Unknown backends must not promote arbitrary native credentials")
        precondition(rows.filter { $0.value == "22222222-2222-4222-8222-222222222222" }.count == 1, "A historical duplicate cannot override the current entry")
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
        for invalid in ["{\"sessionId\":\"secret\"}", "opaque-token", "00000000-0000-0000-0000-000000000000", " 22222222-2222-4222-8222-222222222222", "22222222222242228222222222222222"] {
            precondition(!SessionIdentityPresentation.validNativeID(backend: "claude", id: invalid), "Opaque or malformed native IDs must be rejected")
        }
        precondition(SessionIdentityPresentation.validNativeID(backend: "opencode", id: "ses_012345abcdefAb0123456789zZ"))
        precondition(!SessionIdentityPresentation.validNativeID(backend: "opencode", id: "ses_012345abcdegAb0123456789zZ"))
        let oversizedRows = (0..<300).map { index in
            ["backend": "claude", "id": String(format: "%08x-1111-4111-8111-111111111111", index + 1),
             "status": "new-state", "sourceConversationId": "chat-origin-\(index)"]
        }
        let oversized = try JSONDecoder().decode(SessionIdentities.self, from: JSONSerialization.data(withJSONObject: ["entries": oversizedRows]))
        let bounded = SessionIdentityPresentation.entries(localID: "chat", kind: .conversation, sessions: oversized)
        precondition(oversized.entries.count == 256 && oversized.total == 300 && oversized.truncated)
        precondition(bounded.filter(\.isNative).count == 64 && bounded.filter { $0.kind == .sourceConversation }.count == 64)
        precondition(bounded.filter(\.isNative).allSatisfy { $0.kind == .historical }, "Unknown lifecycle states remain lookup-only")
        print("Session identities: verified formats, bounded optional telemetry, current/saved/history, provenance, old-host fallback and malformed records passed")
    }
}
