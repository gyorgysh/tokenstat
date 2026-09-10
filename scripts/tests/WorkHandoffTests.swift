// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkHandoff.swift.
import Foundation

@main struct WorkHandoffTests {
    static func main() throws {
        let record = #"{"revision":7,"requestId":"share-one","deviceId":"device-a","deviceName":"Studio","updatedAtMs":1789000000000,"draft":{"text":"Keep both versions","attachmentIds":["att-one"]},"anchor":{"eventId":"user-s12","fraction":5000,"followsLatest":false}}"#
        let decoder = JSONDecoder()
        let handoff = try decoder.decode(WorkHandoff.self, from: Data(record.utf8))
        assert(handoff.revision == 7 && handoff.deviceID == "device-a")
        assert(handoff.draft?.attachmentIDs == ["att-one"] && handoff.anchor?.fraction == 5000)
        let saved = try decoder.decode(WorkHandoffResult.self, from: Data("{\"status\":\"saved\",\"handoff\":\(record)}".utf8))
        assert(saved == .saved(handoff))
        let conflict = try decoder.decode(WorkHandoffResult.self, from: Data("{\"status\":\"conflict\",\"current\":\(record)}".utf8))
        assert(conflict == .conflict(handoff))
        let emptyConflict = try decoder.decode(WorkHandoffResult.self, from: Data(#"{"status":"conflict","current":null}"#.utf8))
        assert(emptyConflict == .conflict(nil))
        for invalid in [#"{"status":"saved"}"#, #"{"status":"unknown"}"#] {
            assert((try? decoder.decode(WorkHandoffResult.self, from: Data(invalid.utf8))) == nil)
        }
        let request = WorkHandoffRequest(requestID: "share-two", expectedRevision: 7,
            deviceName: "Phone", draft: handoff.draft, anchor: handoff.anchor)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        assert(json["requestId"] as? String == "share-two")
        assert(json["expectedRevision"] as? Int == 7)
        assert(json["deviceId"] == nil && json["updatedAtMs"] == nil)
        assert(json["clientMessageId"] == nil) // Shared drafts carry no send identity.
        print("Handoff wire: host keys, saved/conflict cases, strict status and no client authority/send fields passed")
    }
}
