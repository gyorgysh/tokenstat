// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with Models.swift JSONValue.swift FileDiff.swift WorkflowLayering.swift.
import Foundation
import SwiftUI

// Unrelated UI/cache types are inert. The models and their actual Codable
// implementations, formatting and arithmetic are compiled from production.
enum Theme {
    static let accent = Color.blue, danger = Color.red, secondary = Color.gray
    static let stateIdle = Color.gray, warning = Color.orange
}
struct WorkReference { var itemID: String?; var workspaceID: String }
struct ChatRoutingState: Codable, Sendable, Hashable {}
struct BranchPull: Codable, Sendable, Hashable {}
struct RelayUsage: Codable, Sendable, Hashable {}
struct ChatTimelineEvent: Codable, Sendable, Hashable {}
struct ChatUsageTotals: Codable, Sendable, Equatable {}

@main struct BridgeModelBoundsTests {
    static func main() throws {
        let counters = Counters(inputFresh: .max, output: 1, total: .max,
                                inputTotal: .max, hasUnknown: false)
        assert(counters.workTokens == .max)
        func bucket(_ value: Int64, estimated: Bool = false, unpriced: [String] = []) -> Bucket {
            Bucket(key: "day", counters: counters, events: 1, sessions: 1,
                   valueMicros: value, estimated: estimated, unpricedModels: unpriced)
        }
        let high = [bucket(.max), bucket(1, estimated: true)].totalValue
        assert(high.micros == .max && high.estimated && high.complete)
        let low = [bucket(.min), bucket(-1, unpriced: ["unknown"])].totalValue
        assert(low.micros == .min && !low.complete)
        assert([bucket(12), bucket(-5)].totalValue.micros == 7)
        assert(LocalModel(id: "model", name: "Model", sizeBytes: .max).sizeDescription != nil)
        let hugeInterval = AutomationSchedule(kind: .interval, everySeconds: .max).summary
        assert(hugeInterval.contains(String(UInt64.max / 3600)))

        let decoder = JSONDecoder()
        let host = try decoder.decode(SSHHost.self, from: Data(#"{"id":"server","label":"Server","hostname":"example.invalid","port":22,"username":"me","credentialID":"key","jumpHostID":"jump","folderID":"folder","hostKeys":["pin"],"provider":{"kind":"aws","resourceID":"instance"}}"#.utf8))
        assert(host.credentialID == "key" && host.jumpHostID == "jump" && host.folderID == "folder")
        assert(host.provider?.resourceID == "instance")
        assert(host.hostKeys == ["pin"] && host.updatedMs == 0 && host.env.isEmpty)
        let encoded = try JSONEncoder().encode(host)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        assert(object["credentialId"] as? String == "key" && object["credentialID"] == nil)
        let hostRoundTrip = try decoder.decode(SSHHost.self, from: encoded)
        assert(hostRoundTrip == host)
        let folder = try decoder.decode(SSHFolder.self, from: Data(#"{"id":"folder","name":"Folder","parentID":"parent"}"#.utf8))
        assert(folder.parentID == "parent" && folder.sort == 0 && folder.updatedMs == 0)
        let folderData = try JSONEncoder().encode(folder)
        let folderRoundTrip = try decoder.decode(SSHFolder.self, from: folderData)
        assert(folderRoundTrip == folder)
        print("Bridge model bounds and legacy vault records passed")
    }
}
