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
        print("Browser navigation: late starts/completions, explicit Go, links and repeated callbacks passed")
    }
}
