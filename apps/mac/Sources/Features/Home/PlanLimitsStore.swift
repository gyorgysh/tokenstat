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
    private var settingsRevision: UInt64 = 0
    struct SettingsRead {
        fileprivate let owner: UInt64
        fileprivate let revision: UInt64
    }
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

    var providers: [ProviderLimits] {
        generation == owner() ? PlanLimitsOrder.ordered(state.providers, source: \.source) : []
    }
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
        if !force, let lastAttempt {
            let age = now().timeIntervalSince(lastAttempt)
            if age >= 0 && age < 30 { return }
        }
        lastAttempt = now()
        let id = UUID()
        let task = Task { @MainActor in
            do {
                let cached = try await readCache()
                guard held == owner(), flight?.id == id else { throw CancellationError() }
                // Retain live readings and failure notes until their replacement
                // arrives. The last-good disk cache cannot clear a rate-limit warning.
                mergeCachedProviders(cached.providers)
                state.enabled = cached.enabled; state.skip = cached.skip
                let providers = try await readLive(force)
                guard held == owner(), flight?.id == id else { throw CancellationError() }
                // Account retains disabled sources so their switches can be turned back on.
                state.providers = providers + cached.providers.filter { previous in
                    cached.skip.contains(previous.source) && !providers.contains { $0.source == previous.source }
                }
            } catch {
                if held == owner(), flight?.id == id, !(error is CancellationError) {
                    state.providers = state.providers.map { var value = $0; value.stale = true; return value }
                }
                throw error
            }
        }
        flight = (id, task)
        defer { if flight?.id == id { flight = nil } }
        try await task.value
        guard held == owner(), !Task.isCancelled else { throw CancellationError() }
    }

    /// A sharing edit retires earlier reads so a late cache reply cannot undo it.
    func settingsChanged(_ settings: LimitsSyncState) {
        settingsRevision &+= 1
        if generation != owner() { state = LimitsSyncState() }
        generation = owner()
        state.enabled = settings.enabled; state.skip = settings.skip
        mergeCachedProviders(settings.providers)
        flight = nil; lastAttempt = nil
    }

    func settingsRead() -> SettingsRead { SettingsRead(owner: owner(), revision: settingsRevision) }

    func acceptCachedSettings(_ settings: LimitsSyncState, requested: SettingsRead) {
        guard requested.owner == owner(), requested.revision == settingsRevision else { return }
        if generation != owner() { settingsChanged(settings); return }
        state.enabled = settings.enabled; state.skip = settings.skip
        mergeCachedProviders(settings.providers)
    }

    /// Settings replies carry last-good numbers, not the outcome of the last
    /// attempt. Equal-dated cache entries must not clear a live failure, while
    /// a newer background reading should reach every surface without HTTP.
    private func mergeCachedProviders(_ providers: [ProviderLimits]) {
        for provider in providers {
            if let index = state.providers.firstIndex(where: { $0.source == provider.source }) {
                if provider.observedAtMs > state.providers[index].observedAtMs {
                    state.providers[index] = provider
                }
            } else {
                state.providers.append(provider)
            }
        }
    }
}
