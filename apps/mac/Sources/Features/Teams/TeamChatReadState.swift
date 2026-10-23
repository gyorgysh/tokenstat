// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import CryptoKit
import Foundation
import Observation

/// Device-local read positions, separate from delivery receipts and authority.
/// Only hashed identifiers and activity times are persisted, never chat text.
@MainActor @Observable
final class TeamChatReadState {
    private let defaults: UserDefaults
    private var namespace: String?
    private var positions: [String: Int64] = [:]
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func bind(to owner: TeamAccountOwner?, person: String? = nil) {
        let next = owner.map { "teams.read.v1." + digest([$0.scope.origin, person ?? $0.personId ?? $0.scope.identity]) }
        guard next != namespace else { return }
        namespace = next
        positions = [:]
        refresh()
    }
    func refresh() {
        guard let namespace else { return }
        let saved: [String: Int64] = (defaults.dictionary(forKey: namespace) ?? [:]).reduce(into: [:]) { result, item in
            guard item.key.count == 64, let number = item.value as? NSNumber, number.int64Value >= 0 else { return }
            result[item.key] = number.int64Value
        }
        for (key, value) in saved { positions[key] = max(positions[key] ?? 0, value) }
    }
    func isUnread(_ share: TeamSharedChat, repository: TeamRepository, checkout: TeamCheckout) -> Bool {
        guard namespace != nil else { return false }
        guard let seen = positions[key(share, repository, checkout)] else { return true }
        return valid(share.lastMessageAtMs) > seen
    }
    func hasRead(_ share: TeamSharedChat, repository: TeamRepository, checkout: TeamCheckout) -> Bool {
        positions[key(share, repository, checkout)] != nil
    }
    func markRead(_ share: TeamSharedChat, repository: TeamRepository, checkout: TeamCheckout, through: Int64?) {
        guard let namespace, share.checkoutId == checkout.id, checkout.repositoryId == repository.id,
            checkout.organizationId == repository.organizationId else { return }
        refresh()
        let id = key(share, repository, checkout)
        let value = max(positions[id] ?? 0, valid(through), valid(share.lastMessageAtMs))
        guard positions[id] != value else { return }
        positions[id] = value
        if positions.count > 4096 {
            for old in positions.filter({ $0.key != id }).sorted(by: { $0.value < $1.value }).prefix(positions.count - 4096) {
                positions.removeValue(forKey: old.key)
            }
        }
        defaults.set(positions, forKey: namespace)
    }
    private func key(_ share: TeamSharedChat, _ repository: TeamRepository, _ checkout: TeamCheckout) -> String {
        digest([repository.organizationId, repository.id, checkout.id, checkout.hostKey, share.id])
    }
    private func valid(_ value: Int64?) -> Int64 {
        guard let value, value > 0, value <= 9_007_199_254_740_991 else { return 0 }
        return value
    }
    private func digest(_ values: [String]) -> String {
        let bytes = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
