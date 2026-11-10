// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Test-only adapters for the original PlanLimitsStore and owner-update method.
// linux-swiftui-contract.py inserts the original method at the marker below.
// Readers are injected; no default bridge, preferences or live host is used.
import Foundation

struct Account: Decodable {
    var signedIn: Bool
    var host: String
    var handle: String?
    var accountId: String?
    var accountSession: String?
    var displayName: String?
    var title: String? { displayName ?? handle }
    var machines: [Machine] { [] }
}
struct SavedWorkOwner { var scope: WorkReference.Scope; var name: String; var hosts: [String:String] }
final class SavedAccessFixture {
    func verified(_ owner: SavedWorkOwner?) {}
    func accountUnknown() {}
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var generation: UInt64 = 0
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
    var accountSession: String?
    let installationID = "fixture-local"
    let savedAccess = SavedAccessFixture()
    /* SOURCE_OWNER_UPDATE */
}
enum Bridge {
    static func limitsSync() async throws -> LimitsSyncState { fatalError("inject cache") }
    static func usageLimits(force: Bool) async throws -> [ProviderLimits] { fatalError("inject live reader") }
}

private func provider(_ reading: Double,_ observed: Int64) -> ProviderLimits {
    ProviderLimits(source: "claude_code", windows: [UsageWindow(label: "weekly",percent: reading,severity: .normal)],observedAtMs: observed)
}
@MainActor private final class VendorGate {
    var calls = 0
    var waiting: [CheckedContinuation<[ProviderLimits],Error>] = []
    func read() async throws -> [ProviderLimits] {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func answer(_ providers: [ProviderLimits]) { waiting.removeFirst().resume(returning: providers) }
    func fail(_ error: Error) { waiting.removeFirst().resume(throwing: error) }
    func reached(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while calls < count {
            if Date() > deadline { throw NSError(domain: "StoreFixtureTimedOut",code: count) }
            await Task.yield()
        }
    }
}
@MainActor private final class StoreReference {
    var owner: UInt64 = 1
    var now: Int64 = 1_000_000
    var cache = LimitsSyncState(providers: [provider(1,1)])
    var cacheCalls = 0
    let gate = VendorGate()
    lazy var store = PlanLimitsStore(owner: { self.owner },readCache: {
        self.cacheCalls += 1
        return self.cache
    },readLive: { _ in try await self.gate.read() },now: { Date(timeIntervalSince1970: Double(self.now)/1000) })
    func start(_ force: Bool) -> Task<Void,Error> { Task { try await store.refresh(force: force) } }
    func row(_ label: String) -> [String:Any] {
        ["label":label,"owner":owner,"cacheCalls":cacheCalls,"liveCalls":gate.calls,
         "enabled":store.enabled,"skip":store.skip,"refreshing":store.isRefreshing,
         "providers":store.providers.map { ["source":$0.source,"percent":$0.windows[0].percent,"stale":$0.isStale,"observed":$0.observedAtMs] as [String:Any] }]
    }
}
@MainActor private func retired(_ task: Task<Void,Error>) async throws {
    do {
        try await task.value
        throw NSError(domain: "RetiredStoreReadAccepted",code: 1)
    } catch is CancellationError {}
}

@MainActor func storeSnapshot(ownersJSON: String) async throws -> [String:Any] {
    let h = StoreReference()
    var rows = [h.row("initial")]
    let first = h.start(false)
    try await h.gate.reached(1); rows.append(h.row("cached"))
    var joined = false
    let second = Task { @MainActor in joined = true; try await h.store.refresh(force: true) }
    while !joined { await Task.yield() }
    rows.append(h.row("joined"))
    first.cancel()
    h.gate.answer([provider(2,2)])
    try await retired(first); try await second.value
    rows.append(h.row("live-after-one-waiter-cancels"))
    try await h.store.refresh(); rows.append(h.row("throttled"))
    let old = h.start(true)
    try await h.gate.reached(2); rows.append(h.row("retained-during-refresh"))
    h.owner = 2; rows.append(h.row("owner-retired"))
    let current = h.start(false)
    try await h.gate.reached(3); rows.append(h.row("new-owner-cache"))
    h.gate.answer([provider(99,99)]); try await retired(old)
    rows.append(h.row("late-owner-reply"))
    h.gate.answer([provider(3,2)]); try await current.value
    rows.append(h.row("new-owner-live"))
    h.now += 31_000
    let failed = h.start(false)
    try await h.gate.reached(4); rows.append(h.row("pending-failure"))
    h.gate.fail(NSError(domain: "OfflineFixture",code: 1))
    do { try await failed.value; throw CancellationError() } catch is CancellationError { throw NSError(domain: "ExpectedFailure",code: 1) } catch {}
    rows.append(h.row("failed-retains-live"))
    try await h.store.refresh(); rows.append(h.row("failed-attempt-throttled"))
    let beforeEdit = h.start(true)
    try await h.gate.reached(5); rows.append(h.row("pending-settings-edit"))
    let read = h.store.settingsRead()
    h.cache.enabled = true; h.cache.skip = ["claude_code"]
    h.store.settingsChanged(h.cache); rows.append(h.row("settings-retire-flight"))
    h.store.acceptCachedSettings(LimitsSyncState(),requested: read); rows.append(h.row("late-settings-cache"))
    h.gate.answer([provider(99,99)]); try await retired(beforeEdit)
    rows.append(h.row("late-settings-vendor"))
    h.cache.providers = [provider(4,3)]
    h.store.acceptCachedSettings(h.cache,requested: h.store.settingsRead()); rows.append(h.row("newer-background-cache"))
    let cancelled = h.start(false)
    try await h.gate.reached(6); rows.append(h.row("pending-cancelled-read"))
    h.gate.fail(CancellationError()); try await retired(cancelled)
    rows.append(h.row("cancel-does-not-mark-stale"))
    let oldRead = h.store.settingsRead(); h.owner = 3
    h.store.acceptCachedSettings(h.cache,requested: oldRead); rows.append(h.row("settings-owner-retired"))
    h.store.acceptCachedSettings(h.cache,requested: h.store.settingsRead()); rows.append(h.row("new-owner-settings"))

    let inputs = try JSONSerialization.jsonObject(with: Data(ownersJSON.utf8)) as! [[String:Any]]
    let context = WorkSessionContext()
    let owners: [[String:Any]] = try inputs.map { row in
        let input = row["input"]!
        let account = input is NSNull ? nil : try JSONDecoder().decode(Account.self,from: JSONSerialization.data(withJSONObject: input))
        context.update(account: account)
        return ["input":input,"generation":context.generation,"session":context.accountSession as Any? ?? NSNull()]
    }
    return ["transcript":rows,"owners":owners]
}
