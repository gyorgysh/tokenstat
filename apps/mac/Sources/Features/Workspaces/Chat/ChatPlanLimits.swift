// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// An open remote chat reads quotas from its host. Account sync remains the
/// source for Home and offline views, without delaying a connected composer.
@MainActor enum ChatPlanLimits {
    private static var hosts: [String: PlanLimitsStore] = [:]

    static func store(peer: String?) -> PlanLimitsStore {
        guard let peer, !peer.isEmpty else { return .shared }
        if let store = hosts[peer] { return store }
        if hosts.count >= 16, let first = hosts.keys.first { hosts.removeValue(forKey: first) }
        let store = PlanLimitsStore(
            owner: { WorkSessionContext.shared.generation },
            // Host settings are local-only. The usage reply already omits
            // disabled providers; retain its last reading in this scoped store.
            readCache: { LimitsSyncState() },
            readLive: { force in
                try await Bridge.onPeer(peer, "usage.limits", ["force": force],
                                        patience: Bridge.Patience.long, as: [ProviderLimits].self)
            })
        hosts[peer] = store
        return store
    }
}
