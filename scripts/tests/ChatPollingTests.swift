// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatPolling.swift.
import Foundation
@MainActor private final class Wire {
    var calls = 0
    var pending: [CheckedContinuation<Void, Never>?] = []
    func read() async { calls += 1; await withCheckedContinuation { pending.append($0) } }
    func finish(_ i: Int) { let held = pending[i]; pending[i] = nil; held?.resume() }
}
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<20000 { if condition() { return }; await Task.yield() }
    precondition(condition(), "Expected controlled async operation did not arrive")
}
@main struct Check {
    @MainActor static func main() async {
        let lane = ChatPollLane<String>(), wire = Wire()
        var published = 0
        let operation: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Bool) async -> Void = { permits in
            await wire.read(); if permits() { published += 1 }
        }
        let shared = (0..<30).compactMap { _ in lane.start(owner: "A", operation: operation) }
        await until { wire.calls == 1 }
        for _ in 0..<30 { _ = lane.start(owner: "A", refresh: true, operation: operation) }
        wire.finish(0)
        await until { wire.calls == 2 }
        precondition(published == 0, "Retired reply published")
        wire.finish(1); for task in shared { await task.value }
        precondition(wire.calls == 2 && published == 1, "Refresh burst was not bounded")
        let old = lane.start(owner: "A", operation: operation)!
        await until { wire.calls == 3 }
        let next = lane.start(owner: "B", operation: operation)!
        await until { wire.calls == 4 }
        wire.finish(2); await old.value
        _ = lane.start(owner: "B", operation: operation)
        for _ in 0..<100 { await Task.yield() }
        precondition(wire.calls == 4 && published == 1, "Old owner cleared/published into successor")
        lane.cancel(owner: "A"); wire.finish(3); await next.value
        precondition(published == 2)
        let canceled = lane.start(owner: "B", operation: operation)!
        await until { wire.calls == 5 }; lane.cancel(); wire.finish(4); await canceled.value
        precondition(published == 2)

        let watcher = ChatPollWatcher<String>(), cycles = Wire()
        var stops = 0
        let start: @MainActor (String) -> Task<Void, Never> = { owner in
            Task { await watcher.watch(owner: owner, cycle: { await cycles.read() },
                                       interval: { .seconds(100) }, stop: { stops += 1 }) }
        }
        let one = start("A"), two = start("A")
        await until { cycles.calls == 1 }
        for _ in 0..<100 { await Task.yield() }
        one.cancel(); await one.value
        precondition(stops == 0, "One view retired the other view's producer")
        two.cancel(); await two.value; await until { stops == 1 }
        let successor = start("B")
        await until { cycles.calls == 2 }
        cycles.finish(0)
        for _ in 0..<100 { await Task.yield() }
        precondition(stops == 1, "Old canceled cycle retired its successor")
        successor.cancel(); await successor.value; await until { stops == 2 }
        cycles.finish(1)
        let displaced = start("A"); await until { cycles.calls == 3 }
        let replacement = start("B"); await until { cycles.calls == 4 }; await displaced.value
        displaced.cancel(); for _ in 0..<100 { await Task.yield() }
        precondition(stops == 3)
        replacement.cancel(); await replacement.value; await until { stops == 4 }
        cycles.finish(2); cycles.finish(3)

        var cadence = ChatPollCadence()
        precondition(cadence.interval(busy: false, attachments: false, now: 0) == .seconds(2))
        precondition(cadence.interval(busy: true, attachments: false, now: 0) == .milliseconds(120))
        for expected in [180, 260, 400, 400] {
            cadence.note(success: true, changed: false, now: 0)
            precondition(cadence.interval(busy: true, attachments: false, now: 0) == .milliseconds(expected))
        }
        cadence.note(success: true, changed: true, now: 10)
        precondition(cadence.interval(busy: false, attachments: false, now: 10.5) == .milliseconds(120))
        precondition(cadence.interval(busy: false, attachments: false, now: 12) == .seconds(2))
        precondition(cadence.interval(busy: false, attachments: true, now: 12) == .milliseconds(120))
        for expected in [400, 800, 1600, 2000, 2000] {
            cadence.note(success: false, changed: false, now: 12)
            precondition(cadence.interval(busy: true, attachments: true, now: 12) == .milliseconds(expected))
        }
        cadence.note(success: true, changed: true, now: 13)
        precondition(cadence.interval(busy: true, attachments: false, now: 13) == .milliseconds(120))
        precondition(cadence.claimStatus(now: 0, force: false))
        precondition(!cadence.claimStatus(now: 0.99, force: false))
        precondition(cadence.claimStatus(now: 1, force: false))
        precondition(cadence.claimStatus(now: 1.01, force: true))
        precondition(cadence.claimApprovals(now: 0, force: false))
        precondition(!cadence.claimApprovals(now: 0.99, force: false))
        precondition(cadence.claimApprovals(now: 0.99, force: true))
        print("Polling: bounded refresh/share, exact owner/leases, cancellation, adaptive cadence")
    }
}
