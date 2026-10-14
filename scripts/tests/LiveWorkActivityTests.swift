// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with LiveWorkActivity.swift and EcosystemSnapshot.swift.
import Foundation

@main struct LiveWorkActivityTests {
    static func main() throws {
        for phase in [LiveWorkPhase.working, .waiting, .idle, .done, .failed, .stopped] {
            let state = LiveWorkAttributes.ContentState(phase: phase, updatedAt: 1_791_283_200)
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(LiveWorkAttributes.ContentState.self, from: data)
            assert(decoded == state)
            let wire = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            assert(Set(wire.keys) == ["phase", "updatedAt"])
            assert(wire["phase"] as? String == phase.rawValue)
            assert(phase.finished == [.done, .failed, .stopped].contains(phase))
            assert(!phase.title.isEmpty)
        }
        let pushed = Data(#"{"phase":"done","updatedAt":1791283200}"#.utf8)
        let completed = try JSONDecoder().decode(LiveWorkAttributes.ContentState.self, from: pushed)
        assert(completed.phase == .done)
        do {
            _ = try JSONDecoder().decode(LiveWorkAttributes.ContentState.self, from: Data(#"{"phase":"unknown","updatedAt":1}"#.utf8))
            assertionFailure("Unexpected phases must not be reported as working.")
        } catch { }
        let host = Data(#"{"working":2,"waiting":1,"idle":4,"done":0,"failed":0,"total":7,"items":[{"key":"b","kind":"chat","phase":"working"},{"key":"a","kind":"terminal","phase":"waiting"}]}"#.utf8)
        let summary = try JSONDecoder().decode(LiveWorkOverview.self, from: host)
        assert(summary.computers == 1 && summary.offline == 0)
        var other = LiveWorkOverview()
        other.working = 3; other.total = 3
        other.items = [.init(key: "c", kind: .chat, phase: .working)]
        let merged = LiveWorkOverview.merged([summary, other], offline: 1)
        assert(merged.total == 10 && merged.working == 5 && merged.waiting == 1 && merged.idle == 4)
        assert(merged.computers == 3 && merged.offline == 1 && merged.phase == .waiting)
        assert(merged.items.map(\.key) == ["a", "b", "c"] && merged.remaining == 7)
        var cleared = summary
        cleared.waiting = 0; cleared.working = 0; cleared.idle = 7
        assert(cleared.phase == .idle, "No working sessions is idle, not waiting.")
        let state = LiveWorkAttributes.ContentState(phase: .waiting, updatedAt: 1, overview: merged)
        let roundtrip = try JSONDecoder().decode(LiveWorkAttributes.ContentState.self, from: JSONEncoder().encode(state))
        assert(roundtrip == state)
        var attributes = LiveWorkAttributes(startedAt: 1, owner: "owner", peer: "peer", key: "key",
            revision: "0", projectName: "Your work", route: "tokenstat://open/workspaces")
        let legacyAttributes = try JSONEncoder().encode(attributes)
        let legacyKeys = Set((try JSONSerialization.jsonObject(with: legacyAttributes) as! [String: Any]).keys)
        assert(legacyKeys == ["startedAt", "owner", "peer", "key", "revision", "projectName", "route"])
        let decodedAttributes = try JSONDecoder().decode(LiveWorkAttributes.self, from: legacyAttributes)
        assert(decodedAttributes.overviewPeers == nil && decodedAttributes.overviewHints == nil)
        attributes.overviewHints = ["a": .init(name: "Terminal", route: "tokenstat://open/workspaces?terminal=a")]
        assert(attributes.preferredRoute(for: state) == attributes.overviewHints?["a"]?.route)
        var idleState = state
        idleState.overview?.items.removeAll()
        assert(attributes.preferredRoute(for: idleState) == attributes.route, "resolved attention cannot retain its old target")
        var unknownState = state
        unknownState.overview?.items[0].key = "new-session"
        assert(attributes.preferredRoute(for: unknownState) == attributes.route)
        print("LiveWorkActivityTests passed")
    }
}
