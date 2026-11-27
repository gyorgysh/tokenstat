// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@MainActor enum ChatPlanLimits {
    private static var hosts: [String: PlanLimitsStore] = [:]

    static func store(peer: String?) -> PlanLimitsStore {
        guard let peer, !peer.isEmpty else { return .shared }
        if let store = hosts[peer] { return store }
        if hosts.count >= 16, let first = hosts.keys.first { hosts.removeValue(forKey: first) }
        let store = PlanLimitsStore(
            owner: { WorkSessionContext.shared.generation },
            readCache: { LimitsSyncState() },
            readLive: { force in
                try await Bridge.onPeer(peer, "usage.limits", ["force": force],
                                        patience: Bridge.Patience.long, as: [ProviderLimits].self)
            })
        hosts[peer] = store
        return store
    }
}
