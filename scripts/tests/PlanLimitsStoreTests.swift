// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with PlanLimitsStore.swift using swiftc -parse-as-library, then run.
import Foundation

struct ProviderLimits: Sendable, Equatable { var source: String; var reading: Int }
struct LimitsSyncState: Sendable {
    var enabled = false
    var skip: [String] = []
    var providers: [ProviderLimits] = []
}
enum PlanLimits { static func visible(_ values: [ProviderLimits]) -> [ProviderLimits] { values } }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var generation: UInt64 = 0 }
enum Bridge {
    static func limitsSync() async throws -> LimitsSyncState { fatalError("inject cache") }
    static func usageLimits(force: Bool) async throws -> [ProviderLimits] { fatalError("inject vendor") }
}

@MainActor final class Gate {
    var calls = 0
    var waiting: [CheckedContinuation<[ProviderLimits], Error>] = []
    func read() async throws -> [ProviderLimits] {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func answer(_ value: Int) { waiting.removeFirst().resume(returning: [ProviderLimits(source: "claude_code", reading: value)]) }
}

@main struct PlanLimitsStoreTests {
    @MainActor static func main() async throws {
        var owner: UInt64 = 1
        var clock = Date(timeIntervalSince1970: 1_000)
        let gate = Gate()
        let store = PlanLimitsStore(owner: { owner }, readCache: {
            LimitsSyncState(providers: [ProviderLimits(source: "claude_code", reading: 1)])
        }, readLive: { _ in try await gate.read() }, now: { clock })
        let first = Task { try await store.refresh() }
        while gate.calls == 0 { await Task.yield() }
        precondition(store.providers.first?.reading == 1, "cached readings publish before slow vendor")
        let second = Task { try await store.refresh() }
        await Task.yield()
        precondition(gate.calls == 1, "screens share one live request")
        first.cancel()
        gate.answer(2)
        do { try await first.value; preconditionFailure("cancelled waiter accepted result") } catch is CancellationError {}
        try await second.value
        precondition(store.providers.first?.reading == 2, "another waiter retains the shared result")
        try await store.refresh()
        precondition(gate.calls == 1, "automatic reads are throttled across mounts")
        let manual = Task { try await store.refresh(force: true) }
        while gate.calls < 2 { await Task.yield() }
        owner = 2
        precondition(store.providers.isEmpty, "old account readings disappear immediately")
        let changed = Task { try await store.refresh() }
        while gate.calls < 3 { await Task.yield() }
        gate.answer(99)
        do { try await manual.value; preconditionFailure("retired reply accepted") } catch is CancellationError {}
        precondition(store.providers.first?.reading == 1, "retired reply cannot overwrite new account cache")
        gate.answer(3)
        try await changed.value
        precondition(store.providers.first?.reading == 3)
        clock.addTimeInterval(31)
        let overdue = Task { try await store.refresh() }
        while gate.calls < 4 { await Task.yield() }
        store.settingsChanged(LimitsSyncState(enabled: true, skip: ["claude_code"]))
        gate.answer(4)
        do { try await overdue.value; preconditionFailure("sharing edit overwritten") } catch is CancellationError {}
        precondition(store.enabled && store.visible.isEmpty && store.providers.isEmpty, "empty cache clears an old reading")
        let skipped = PlanLimitsStore(owner: { owner }, readCache: {
            LimitsSyncState(skip: ["claude_code"], providers: [ProviderLimits(source: "claude_code", reading: 1)])
        }, readLive: { _ in [] })
        try await skipped.refresh()
        precondition(skipped.providers.count == 1 && skipped.visible.isEmpty, "Account retains a disabled source's switch; composers and Home hide it")
        print("PlanLimitsStoreTests passed: cache, sharing, cancellation, throttle and account retirement")
    }
}
