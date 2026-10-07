// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TunnelRecoveryFlights.swift.
import Foundation
@MainActor private final class Wire {
    var calls = 0
    var pending: [CheckedContinuation<Void, Never>?] = []
    func call() async { calls += 1; await withCheckedContinuation { pending.append($0) } }
    func finish(_ index: Int) { let held = pending[index]; pending[index] = nil; held?.resume() }
}
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<10000 { if condition() { return }; await Task.yield() }
    precondition(condition())
}
@main struct Check {
    @MainActor static func main() async {
        let flights = TunnelRecoveryFlights(), wire = Wire(), owner = Data("A".utf8)
        let soft = (0..<30).map { _ in Task { await flights.run(owner: owner, urgency: .soft) { await wire.call() } } }
        await until { wire.calls == 1 }
        let foreground = Task { await flights.run(owner: owner, urgency: .foreground) { await wire.call() } }
        await until { wire.calls == 2 } // Stronger work starts before old timeout.
        wire.finish(0)
        for task in soft { await task.value }
        let join = Task { await flights.run(owner: owner, urgency: .soft) { await wire.call() } }
        for _ in 0..<100 { await Task.yield() }
        precondition(wire.calls == 2, "Old completion erased foreground work")
        let other = Task { await flights.run(owner: Data("B".utf8), urgency: .soft) { await wire.call() } }
        await until { wire.calls == 3 }
        wire.finish(1); wire.finish(2)
        await foreground.value; await join.value; await other.value
        let next = Task { await flights.run(owner: owner, urgency: .soft) { await wire.call() } }
        await until { wire.calls == 4 }; wire.finish(3); await next.value
        let canceled = Task { await Task.yield(); await flights.run(owner: owner, urgency: .soft) { await wire.call() } }
        canceled.cancel(); await canceled.value
        precondition(wire.calls == 4)
        print("Recovery: shared reads, immediate urgency, exact teardown, account isolation")
    }
}
