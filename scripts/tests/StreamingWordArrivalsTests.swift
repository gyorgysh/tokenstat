// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with StreamingWordArrivals.swift.
import Foundation
@main struct StreamingWordArrivalsTests {
    static func main() {
        let state = StreamingWordArrivals()
        precondition(state.update(source: "Already here", count: 2, now: 0).isEmpty)
        let first = state.update(source: "Already here new", count: 3, now: 1)
        precondition(first == [2: 1])
        let second = state.update(source: "Already here newer word", count: 4, now: 1.1)
        precondition(second == [2: 1, 3: 1.1], "Earlier words must not restart their fade")
        precondition(state.update(source: "Already here newer word", count: 4, now: 2).isEmpty)
        precondition(state.update(source: "Restored history with more words", count: 5, now: 3).isEmpty)
        precondition(state.update(source: "Restored", count: 1, now: 4).isEmpty)
        precondition(state.update(source: "Restored history with more words", count: 5, now: 4.01).isEmpty)
        precondition(state.update(source: "Restored history with more words next", count: 6, now: 4.02) == [5: 4.02])
        _ = state.update(source: "Restored history with more words next", count: 6, now: 4.03, animate: false)
        precondition(state.update(source: "Restored history with more words next", count: 6, now: 4.04).isEmpty)
        let reopened = StreamingWordArrivals()
        precondition(reopened.update(source: "Restored", count: 1, now: 5).isEmpty)
        precondition(reopened.update(source: "Restored words in another chat", count: 5, now: 5.01, identity: "other").isEmpty)
        print("Word fade: initial history, append-only arrivals, no replay, expiry and reopened views passed")
    }
}
