// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHInputQueue.swift SSHCompletionReplacement.swift.
import Foundation

@main struct SSHInputQueueTests {
    @MainActor static func main() async throws {
        let queue = SSHInputQueue()
        var calls: [String] = []
        var waiter: CheckedContinuation<Void, Never>?
        let first = queue.enqueue {
            calls.append("first-start")
            await withCheckedContinuation { waiter = $0 }
            calls.append("first-end")
            return true
        }
        let second = queue.enqueue { calls.append("second"); return true }
        for _ in 0..<200 {
            if waiter != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        assert(waiter != nil && calls == ["first-start"], "second write cannot overtake suspended first write")
        waiter?.resume()
        _ = await first.value
        _ = await second.value
        assert(calls == ["first-start", "first-end", "second"])
        let retired = queue.enqueue { false }
        let later = queue.enqueue { calls.append("later"); return true }
        let retiredResult = await retired.value
        let laterResult = await later.value
        assert(!retiredResult && laterResult)
        assert(calls.last == "later")
        assert(SSHCompletionReplacement.count(replacing: -1, fragment: "ab", current: "abc") == nil)
        assert(SSHCompletionReplacement.count(replacing: Int.max, fragment: "ab", current: "abc") == nil)
        assert(SSHCompletionReplacement.count(replacing: 2, fragment: "ab", current: "abc") == 3)
        assert(SSHCompletionReplacement.count(replacing: 1, fragment: "ab", current: "changed") == nil)
        print("SSH input order and completion replacement bounds passed")
    }
}
