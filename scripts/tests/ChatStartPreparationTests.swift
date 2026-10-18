// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatStartPreparation.swift.
import Foundation

@MainActor private final class Send {
    var calls = 0
    var finished = false
    var cancelled = false
    var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        cancelled = Task.isCancelled
        finished = true
    }
    func complete() { continuation?.resume(); continuation = nil }
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<20000 { if condition() { return }; await Task.yield() }
    precondition(condition(), "Expected controlled send did not arrive")
}

@main struct ChatStartPreparationTests {
    @MainActor static func main() async {
        let clock = ContinuousClock()
        let began = clock.now
        var quickCalls = 0
        await ChatStartPreparation.preload(until: began.advanced(by: .seconds(10))) { quickCalls += 1 }
        precondition(quickCalls == 1 && began.duration(to: clock.now) < .seconds(1),
                     "A ready message opens immediately without spending an animation minimum")

        let slow = Send()
        await ChatStartPreparation.preload(until: clock.now.advanced(by: .milliseconds(20))) { await slow.run() }
        precondition(slow.calls == 1 && !slow.finished,
                     "A slow host must not keep the conversation behind the prism")
        slow.complete()
        await until { slow.finished }
        precondition(!slow.cancelled && slow.calls == 1, "The presentation timeout never cancels or duplicates delivery")

        let leaving = Send()
        let waiter = Task {
            await ChatStartPreparation.preload(until: clock.now.advanced(by: .seconds(60))) { await leaving.run() }
        }
        await until { leaving.continuation != nil }
        waiter.cancel()
        await waiter.value
        precondition(!leaving.finished)
        leaving.complete()
        await until { leaving.finished }
        precondition(!leaving.cancelled && leaving.calls == 1,
                     "Leaving the page retires the wait while the authorized send retains its receipt")

        var lateCalls = 0
        await ChatStartPreparation.preload(until: clock.now.advanced(by: .milliseconds(-1))) { lateCalls += 1 }
        await until { lateCalls == 1 }
        print("First send preload: immediate completion, bounded wait, preserved delivery after timeout/navigation and no duplicated sends passed")
    }
}
