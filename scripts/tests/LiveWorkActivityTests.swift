// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with LiveWorkActivity.swift.
import Foundation

@main struct LiveWorkActivityTests {
    static func main() throws {
        for phase in [LiveWorkPhase.working, .waiting, .done, .failed, .stopped] {
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
        print("LiveWorkActivityTests passed")
    }
}
