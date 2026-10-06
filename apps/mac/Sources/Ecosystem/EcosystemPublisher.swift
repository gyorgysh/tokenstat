// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit
import CoreSpotlight
import WidgetKit
import AppIntents

/// The app is the sole snapshot writer. A lease prevents an asynchronous load
/// from publishing across sign-out, including signing back into the same account.
@MainActor
enum EcosystemPublisher {
    private static let store = EcosystemSnapshotStore()
    private static var verifiedOwner: String?
    private static var generation = UUID()
    private static var allowedPeers: Set<String> = []
    private static var limitsRefreshTask: Task<Void, Error>?
    private static var refreshTask: Task<Void, Error>?
    private static var indexing: Task<Void, Never>?

    static var lease: EcosystemPublicationLease? {
        verifiedOwner.map { EcosystemPublicationLease(owner: $0, generation: generation) }
    }

    static func ownerKey(_ scope: WorkReference.Scope?) -> String? {
        guard let scope else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(scope) else { return nil }
        // Navigation and entity identifiers must not disclose account identity.
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyOwner(account: Account?, loadInitial: Bool = true) {
        #if os(iOS)
        guard account?.signedIn == true else { clear(); return }
        #endif
        guard let owner = ownerKey(WorkSessionContext.shared.scope) else { return }
        let newlyVerified = verifiedOwner != owner
        if newlyVerified { generation = UUID() }
        verifiedOwner = owner
        allowedPeers = Set(account?.machines.filter { $0.trustState != "revoked" }.compactMap(\.publicIdentity) ?? [])
        #if os(iOS)
        LiveWorkController.shared.verify(owner: owner)
        #endif
        var snapshot = store.read()
        let previousProjects = snapshot.projects
        if snapshot.owner != owner { snapshot = EcosystemSnapshot(owner: owner) }
        snapshot.projects.removeAll { !authorized($0) }
        save(snapshot)
        if newlyVerified || previousProjects != snapshot.projects { updateProjectDiscovery(snapshot) }
        #if os(iOS)
        EcosystemWatchSync.shared.publish(snapshot)
        #endif
        guard newlyVerified, loadInitial, let lease else { return }
        Task {
            await BridgeLaunch.wait()
            guard isCurrent(lease) else { return }
            do {
                let grid = try await Bridge.activityCalendar(scope: activityScope)
                publish(calendar: grid, lease: lease)
            } catch { /* Keep the last successful snapshot while offline. */ }
            await refreshLimits(lease: lease)
            #if os(macOS)
            if let folders = try? await Bridge.workspaces() {
                publish(projects: folders.filter(\.exists).map {
                    EcosystemProject(id: $0.id, name: $0.name, host: "This Mac")
                }, lease: lease, replacing: .local)
            }
            #endif
        }
    }

    private static var activityScope: String {
        (ActivityScope(rawValue: UserDefaults.standard.string(forKey: "activity.scope") ?? "") ?? .allMachines).wire
    }

    static func clear() {
        #if os(iOS)
        LiveWorkController.shared.verify(owner: nil)
        #endif
        generation = UUID()
        verifiedOwner = nil
        allowedPeers = []
        save(.empty)
        updateProjectDiscovery(.empty)
    }

    static func isCurrent(_ lease: EcosystemPublicationLease?) -> Bool {
        guard let lease else { return false }
        return lease == self.lease && lease.owner == ownerKey(WorkSessionContext.shared.scope)
    }

    static func isAuthorizedPeer(_ peer: String) -> Bool { verifiedOwner != nil && allowedPeers.contains(peer) }

    /// Runs in the containing app, even when invoked from a widget. No peer
    /// dial, agent execution or foreground navigation is needed for usage.
    static func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    static func refreshLimitsOnly() async throws {
        if let limitsRefreshTask { return try await limitsRefreshTask.value }
        let task = Task { try await performLimitsRefresh() }
        limitsRefreshTask = task
        defer { limitsRefreshTask = nil }
        try await task.value
    }

    private static func performLimitsRefresh() async throws {
        let startingGeneration = generation
        BridgeLaunch.begin()
        await BridgeLaunch.wait()
        let account = try await Bridge.account()
        guard generation == startingGeneration else { throw EcosystemIntentError.sessionChanged }
        WorkSessionContext.shared.update(account: account)
        verifyOwner(account: account, loadInitial: false)
        guard let lease else { throw EcosystemIntentError.usageUnavailable }
        guard await refreshLimits(lease: lease) else { throw EcosystemIntentError.usageUnavailable }
    }

    private static func performRefresh() async throws {
        let startingGeneration = generation
        var refreshLease = lease
        do {
            BridgeLaunch.begin()
            await BridgeLaunch.wait()
            let account = try await Bridge.account()
            guard generation == startingGeneration else { throw EcosystemIntentError.sessionChanged }
            WorkSessionContext.shared.update(account: account)
            verifyOwner(account: account, loadInitial: false)
            guard let lease else { throw EcosystemIntentError.usageUnavailable }
            refreshLease = lease
            await refreshLimits(lease: lease)
            let grid = try await Bridge.activityCalendar(scope: activityScope, force: true)
            guard isCurrent(lease) else { throw EcosystemIntentError.sessionChanged }
            publish(calendar: grid, lease: lease)
            #if os(macOS)
            if let folders = try? await Bridge.workspaces() {
                publish(projects: folders.filter(\.exists).map {
                    EcosystemProject(id: $0.id, name: $0.name, host: "This Mac")
                }, lease: lease, replacing: .local)
            }
            #endif
        } catch {
            if isCurrent(refreshLease) {
                var snapshot = store.read()
                snapshot.refreshFailed = true
                save(snapshot)
            }
            throw error
        }
    }

    static func publish(calendar: ActivityCalendar?, lease: EcosystemPublicationLease?) {
        guard isCurrent(lease), let lease else { return }
        var snapshot = store.read()
        guard snapshot.owner == lease.owner else { return }
        if let calendar {
            guard let fetchedAt = calendar.fetchedAt, fetchedAt.timeIntervalSince1970.isFinite else {
                snapshot.refreshFailed = true; save(snapshot); return
            }
            if let previous = snapshot.usage?.updatedAt, fetchedAt < previous { return }
        }
        snapshot.refreshFailed = calendar?.noticeCode == "stale" ? true : nil
        snapshot.usage = calendar.map { grid in
            EcosystemUsage(updatedAt: grid.fetchedAt ?? .distantPast,
                           scope: grid.scope == "account" ? "All devices" : "This device",
                           days: Array(grid.rows.flatMap { $0.compactMap { $0 } }
                            .sorted { $0.date < $1.date }.suffix(35)).map {
                                EcosystemDay(day: $0.date, value: $0.value, level: min(4, max(0, $0.level)), locked: $0.isLocked)
                            }, streak: max(0, grid.streakCurrent))
        }
        save(snapshot)
    }

    static func publish(limits: [ProviderLimits], lease: EcosystemPublicationLease?) {
        guard isCurrent(lease), let lease else { return }
        var snapshot = store.read()
        guard snapshot.owner == lease.owner else { return }
        let previous = Dictionary(uniqueKeysWithValues: (snapshot.limits ?? []).map { ($0.source, $0) })
        var seen = Set<String>()
        snapshot.limits = Array(limits.compactMap { provider -> EcosystemLimitProvider? in
            guard let observed = provider.observedAt else { return nil }
            let reading = EcosystemLimitProvider(source: provider.source, observedAt: observed, stale: provider.isStale,
                windows: Array(provider.windows.prefix(8)).map {
                    EcosystemLimitWindow(label: $0.displayLabel, percent: $0.percent, resetsAt: $0.resetsAt)
                })
            guard reading.isValid, seen.insert(reading.source).inserted else { return nil }
            return previous[reading.source].flatMap { $0.observedAt > reading.observedAt ? $0 : nil } ?? reading
        }.prefix(32))
        save(snapshot)
    }

    @discardableResult private static func refreshLimits(lease: EcosystemPublicationLease) async -> Bool {
        do {
            let settings = try await Bridge.limitsSync()
            guard isCurrent(lease) else { return false }
            let providers = try await Bridge.usageLimits()
            publish(limits: providers.filter { !settings.skip.contains($0.source) }, lease: lease)
            return isCurrent(lease)
        } catch {
            guard isCurrent(lease) else { return false }
            var snapshot = store.read()
            snapshot.limits = snapshot.limits?.map { var reading = $0; reading.stale = true; return reading }
            save(snapshot)
            return false
        }
    }

    static func publish(projects: [EcosystemProject], lease: EcosystemPublicationLease?, replacing source: EcosystemProjectSource) {
        guard isCurrent(lease), let lease else { return }
        var snapshot = store.read()
        guard snapshot.owner == lease.owner else { return }
        // The source is explicit so an empty successful response removes its
        // previous projects without removing another machine's cached list.
        snapshot.replaceProjects(projects.filter { authorized($0) && source.contains($0.id) }, from: source)
        save(snapshot)
        updateProjectDiscovery(snapshot)
    }

    private static func updateProjectDiscovery(_ snapshot: EcosystemSnapshot) {
        let previous = indexing
        let requestedLease = lease
        indexing = Task {
            await previous?.value
            guard snapshot.owner == nil || isCurrent(requestedLease) else { return }
            if #available(iOS 18.0, macOS 15.0, *) {
                let index = CSSearchableIndex.default()
                // Serialize deletion/indexing so a late index cannot outlive sign-out.
                try? await index.deleteAppEntities(ofType: TokenstatProjectEntity.self)
                if let owner = snapshot.owner, isCurrent(requestedLease) {
                    try? await index.indexAppEntities(snapshot.projects.map { TokenstatProjectEntity(project: $0, owner: owner) })
                }
            }
            await Task.detached(priority: .utility) { TokenstatAppShortcuts.updateAppShortcutParameters() }.value
        }
    }

    private static func authorized(_ project: EcosystemProject) -> Bool {
        let parts = project.id.split(separator: ":", maxSplits: 2)
        guard parts.first == "remote" else { return true }
        return parts.count == 3 && allowedPeers.contains(String(parts[1]))
    }

    private static func save(_ snapshot: EcosystemSnapshot) {
        guard snapshot != store.read(), store.write(snapshot) else { return }
        for kind in EcosystemSnapshotStore.widgetKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        #if os(iOS)
        EcosystemWatchSync.shared.publish(snapshot)
        #endif
    }
}
