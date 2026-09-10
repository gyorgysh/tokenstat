// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Last verified workspace-access answers. Unknown is not permission. Search
/// uses these local facts without contacting hosts while the person types.
@MainActor @Observable
final class WorkAccessStore {
    static let shared = WorkAccessStore()
    private(set) var generation: UInt64 = 0
    private let defaults: UserDefaults
    private struct Envelope: Codable {
        let version: Int
        let scope: WorkReference.Scope
        var hosts: [String: Bool]
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func allowed(scope: WorkReference.Scope, host: String) -> Bool? {
        _ = generation
        return envelope(scope)?.hosts[host]
    }

    func record(_ allowed: Bool, scope: WorkReference.Scope, host: String) {
        guard !host.isEmpty, host.utf8.count <= 512 else { return }
        var stored = envelope(scope) ?? Envelope(version: 1, scope: scope, hosts: [:])
        guard stored.hosts[host] != allowed else { return }
        stored.hosts[host] = allowed
        guard stored.hosts.count <= 256, let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key(scope))
        generation &+= 1
    }

    func clear(scope: WorkReference.Scope) {
        defaults.removeObject(forKey: key(scope))
        generation &+= 1
    }

    private func envelope(_ scope: WorkReference.Scope) -> Envelope? {
        guard let data = defaults.data(forKey: key(scope)), data.count <= 256 * 1024,
              let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.version == 1, value.scope == scope, value.hosts.count <= 256,
              value.hosts.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { return nil }
        return value
    }

    private func key(_ scope: WorkReference.Scope) -> String {
        "work.workspaceAccess.v1." + [scope.kind.rawValue, scope.origin, scope.identity]
            .map(WorkReferenceKey.encode).joined(separator: "|")
    }
}
