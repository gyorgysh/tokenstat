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
        var arrivals: [Int: TimeInterval] = [0: 10, 1: 11, 4: 14, 8: 18]
        let window = StreamingWordWindow(arrivals)
        precondition(window.words(in: 0..<2) == [0: 10, 1: 11])
        precondition(window.words(in: 2..<2).isEmpty)
        precondition(window.words(in: 2..<4).isEmpty)
        precondition(window.words(in: 4..<9) == [4: 14, 8: 18])
        precondition(window.words(in: 0..<9) == arrivals)
        precondition(window.words(in: 9..<20).isEmpty)
        precondition(StreamingWordWindow([:]).words(in: 0..<10).isEmpty)
        arrivals[1] = 99
        precondition(window.words(in: 1..<2) == [1: 11], "A rendered window keeps its own timestamp snapshot")
        let burst = Dictionary(uniqueKeysWithValues: (4000..<10000).map { ($0, TimeInterval($0)) })
        let longWindow = StreamingWordWindow(burst)
        var restored: [Int: TimeInterval] = [:]
        for start in stride(from: 0, to: 10000, by: 100) {
            for (word, time) in longWindow.words(in: start..<start + 100) {
                precondition(restored.updateValue(time, forKey: word) == nil, "A fade belongs to one chunk")
            }
        }
        precondition(restored == burst, "Chunking preserves every word and its original arrival time")
        print("Word fade: initial history, append-only arrivals, no replay, expiry and reopened views passed")
    }
}
