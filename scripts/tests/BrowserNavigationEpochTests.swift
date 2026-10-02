// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with BrowserNavigationEpoch.swift.
import Foundation

@main struct BrowserNavigationEpochTests {
    static func main() {
        let old = NSObject()
        let next = NSObject()
        let link = NSObject()
        var epochs = BrowserNavigationEpoch()
        epochs.current = 1
        epochs.register(old, generation: 1)
        epochs.current = 2
        epochs.register(next, generation: 2)
        precondition(!epochs.started(old), "A queued old start took ownership of the new page")
        precondition(epochs.finish(old) == nil, "An old completion replaced a new address")
        precondition(epochs.started(next) && epochs.finish(next) == .init(generation: 2, registered: true))
        precondition(epochs.started(link) && epochs.finish(link) == .init(generation: 2, registered: false), "An in-page link lost the current owner")
        precondition(epochs.finish(next) == nil && epochs.finish(nil) == nil)
        let stateOnly = NSObject()
        epochs.register(stateOnly, generation: 2)
        epochs.abandonIfNotStarted(stateOnly)
        epochs.current = 3
        precondition(epochs.started(stateOnly) && epochs.finish(stateOnly) == .init(generation: 3, registered: false),
                     "A state-only Back retained an old navigation owner")
        let documentBack = NSObject()
        epochs.register(documentBack, generation: 3)
        precondition(epochs.started(documentBack))
        epochs.abandonIfNotStarted(documentBack)
        precondition(epochs.finish(documentBack) == .init(generation: 3, registered: true),
                     "A document Back lost its completion after popstate")
        print("Browser navigation: late starts/completions, explicit Go, links and repeated callbacks passed")
    }
}
