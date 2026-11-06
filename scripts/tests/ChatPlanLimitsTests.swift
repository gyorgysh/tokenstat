// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatPlanLimits.swift and PlanLimitsStore.swift and PlanLimitsOrder.swift.
import Foundation

struct ProviderLimits: Sendable, Equatable {
    var source: String; var reading: Int; var stale: Bool? = nil
    var observedAtMs: Int64 = 1
}
struct LimitsSyncState: Sendable {
    var enabled = false
    var skip: [String] = []
    var providers: [ProviderLimits] = []
}
enum PlanLimits { static func visible(_ values: [ProviderLimits]) -> [ProviderLimits] { values } }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var generation: UInt64 = 0 }
@MainActor enum Bridge {
    enum Patience { static let long: TimeInterval = 60 }
    static var calls: [String] = []
    static func limitsSync() async throws -> LimitsSyncState { LimitsSyncState() }
    static func usageLimits(force: Bool) async throws -> [ProviderLimits] { [] }
    static func onPeer<T>(_ peer: String, _ method: String, _ params: [String: Any], patience: TimeInterval = 30, as: T.Type) async throws -> T {
        calls.append("\(peer):\(method)")
        if method == "config.limitsSync" { return LimitsSyncState() as! T }
        precondition(method == "usage.limits" && params["force"] as? Bool == false)
        return [ProviderLimits(source: "codex", reading: peer == "a" ? 10 : 20)] as! T
    }
}
@main struct ChatPlanLimitsTests {
    @MainActor static func main() async throws {
        precondition(ChatPlanLimits.store(peer: nil) === PlanLimitsStore.shared)
        let a = ChatPlanLimits.store(peer: "a")
        let same = ChatPlanLimits.store(peer: "a")
        let b = ChatPlanLimits.store(peer: "b")
        precondition(a === same && a !== b)
        try await a.refresh()
        try await same.refresh()
        try await b.refresh()
        precondition(a.providers.first?.reading == 10 && b.providers.first?.reading == 20)
        precondition(Bridge.calls == ["a:usage.limits", "b:usage.limits"])
        WorkSessionContext.shared.generation += 1
        precondition(a.providers.isEmpty && b.providers.isEmpty)
        try await a.refresh()
        precondition(a.providers.first?.reading == 10 && b.providers.isEmpty)
        print("Chat quotas: host routes, shared requests, host separation and account retirement passed")
    }
}
