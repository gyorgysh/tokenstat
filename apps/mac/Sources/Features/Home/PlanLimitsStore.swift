// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// One dated reading for Home, Account and every composer. Visible readers
/// share a request; changing accounts retires both the result and its flight.
@MainActor @Observable
final class PlanLimitsStore {
    static let shared = PlanLimitsStore(
        owner: { WorkSessionContext.shared.generation },
        readCache: { try await Bridge.limitsSync() },
        readLive: { try await Bridge.usageLimits(force: $0) }
    )

    private var state = LimitsSyncState()
    private var generation: UInt64?
    private var lastAttempt: Date?
    private var flight: (id: UUID, task: Task<Void, Error>)?
    private let owner: () -> UInt64
    private let readCache: () async throws -> LimitsSyncState
    private let readLive: (Bool) async throws -> [ProviderLimits]
    private let now: () -> Date

    init(owner: @escaping () -> UInt64,
         readCache: @escaping () async throws -> LimitsSyncState,
         readLive: @escaping (Bool) async throws -> [ProviderLimits],
         now: @escaping () -> Date = Date.init) {
        self.owner = owner; self.readCache = readCache; self.readLive = readLive; self.now = now
    }

    var providers: [ProviderLimits] { generation == owner() ? state.providers : [] }
    var skip: [String] { generation == owner() ? state.skip : [] }
    var enabled: Bool { generation == owner() && state.enabled }
    var visible: [ProviderLimits] { PlanLimits.visible(providers).filter { !skip.contains($0.source) } }
    var isRefreshing: Bool { generation == owner() && flight != nil }

    func refresh(force: Bool = false) async throws {
        let held = owner()
        if generation != held {
            state = LimitsSyncState(); generation = held; flight = nil; lastAttempt = nil
        }
        if let flight {
            try await flight.task.value
            guard held == owner(), !Task.isCancelled else { throw CancellationError() }
            return
        }
        if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < 30 { return }
        lastAttempt = now()
        let id = UUID()
        let task = Task { @MainActor in
            let cached = try await readCache()
            guard held == owner(), flight?.id == id else { throw CancellationError() }
            state = cached
            let providers = try await readLive(force)
            guard held == owner(), flight?.id == id else { throw CancellationError() }
            // Account keeps disabled sources so their switches can be turned
            // back on. Other surfaces filter them through `visible`.
            state.providers = providers + cached.providers.filter { previous in
                cached.skip.contains(previous.source) && !providers.contains { $0.source == previous.source }
            }
        }
        flight = (id, task)
        defer { if flight?.id == id { flight = nil } }
        try await task.value
        guard held == owner(), !Task.isCancelled else { throw CancellationError() }
    }

    /// A sharing edit retires earlier reads so a late cache reply cannot undo it.
    func settingsChanged(_ settings: LimitsSyncState) {
        generation = owner(); state = settings; flight = nil; lastAttempt = nil
    }

    func acceptCachedSettings(_ settings: LimitsSyncState) {
        if generation != owner() { settingsChanged(settings); return }
        state.enabled = settings.enabled; state.skip = settings.skip
        if state.providers.isEmpty { state.providers = settings.providers }
    }
}
