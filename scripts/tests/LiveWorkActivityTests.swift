// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with LiveWorkActivity.swift and EcosystemSnapshot.swift.
import Foundation

@main struct LiveWorkActivityTests {
    private struct LegacyContentState: Decodable {
        var phase: LiveWorkPhase
        var updatedAt: Double
    }

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
        let hint = try JSONDecoder().decode(LiveWorkHostOverview.Hint.self,
            from: Data(#"{"key":"a","kind":"terminal","id":"terminal","workspaceId":"project","name":"Project"}"#.utf8))
        assert(hint.workspaceID == "project")
        let hintWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hint)) as! [String: Any]
        assert(hintWire["workspaceId"] as? String == "project" && hintWire["workspaceID"] == nil)
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
        var finished = LiveWorkOverview()
        finished.done = 2; finished.total = 2
        finished.items = [.init(key: "finished", kind: .chat, phase: .done)]
        assert(finished.phase == .idle, "Completion must not end an overview subscription.")
        assert(finished.displayPhase == .done, "Completed work must not be presented as idle.")
        let finishedState = LiveWorkAttributes.ContentState(phase: .idle, updatedAt: 1, overview: finished)
        assert(finishedState.displayPhase == .done)
        assert(finishedState.displayPhase(stale: false) == .done)
        assert(finishedState.displayPhase(stale: true) == .idle,
               "A stale overview must show reconnecting even when its last result was done.")
        var failedState = finishedState
        failedState.overview?.done = 0
        failedState.overview?.failed = 2
        assert(failedState.displayPhase(stale: false) == .failed)
        assert(failedState.displayPhase(stale: true) == .idle)
        let legacyDone = LiveWorkAttributes.ContentState(phase: .done, updatedAt: 1)
        assert(legacyDone.displayPhase(stale: true) == .done,
               "A legacy completed activity must keep its final result when stale.")
        let finishedWire = try JSONEncoder().encode(finishedState)
        let finishedKeys = Set((try JSONSerialization.jsonObject(with: finishedWire) as! [String: Any]).keys)
        assert(finishedKeys == ["phase", "updatedAt", "overview"], "Presentation changes must not alter the wire schema.")
        let oldClient = try JSONDecoder().decode(LegacyContentState.self, from: finishedWire)
        assert(oldClient.phase == .idle && oldClient.updatedAt == finishedState.updatedAt,
               "An older app must keep receiving updates after the overview completes.")
        finished.failed = 1; finished.total = 3
        assert(finished.displayPhase == .failed)
        finished.idle = 1; finished.total = 4
        assert(finished.displayPhase == .failed, "An idle shell must not hide a failed run.")
        finished.working = 1; finished.total = 5
        assert(finished.displayPhase == .working)
        finished.waiting = 1; finished.total = 6
        assert(finished.displayPhase == .waiting)
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
