// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Device-local SSH handles only appear under projects they were attached to.
/// The account, verified computer and workspace identify each association.
@MainActor @Observable
final class ClientSSHProjectLinks {
    private struct Record: Codable, Equatable {
        var projects: [String: [String]] = [:]
        var names: [String: String] = [:]
    }

    @ObservationIgnored private let isOwnerCurrent: @MainActor () -> Bool
    @ObservationIgnored private let scope: WorkReference.Scope?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let namespace: String?
    private var record: Record

    init(scope: WorkReference.Scope?, defaults: UserDefaults = .standard,
         storageKey: String = "client.sshProjectLinks.v1", isOwnerCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.isOwnerCurrent = isOwnerCurrent
        self.scope = scope
        self.defaults = defaults
        self.storageKey = storageKey
        namespace = scope.map {
            WorkReferenceKey.folder(scope: $0, hostIdentity: "device-ssh", workspaceID: "links")
        }
        let stored = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([String: Record].self, from: $0)
        } ?? [:]
        record = namespace.flatMap { stored[$0] } ?? Record()
    }

    func sessions(peer: String, workspace: String) -> [String] {
        guard let key = projectKey(peer: peer, workspace: workspace) else { return [] }
        return record.projects[key] ?? []
    }

    func attach(_ sessionID: String, peer: String, workspace: String) {
        guard !sessionID.isEmpty, let key = projectKey(peer: peer, workspace: workspace) else { return }
        update { record in
            var ids = record.projects[key] ?? []
            if !ids.contains(sessionID) { ids.append(sessionID) }
            record.projects[key] = ids
        }
    }

    func detach(_ sessionID: String, peer: String, workspace: String) {
        guard let key = projectKey(peer: peer, workspace: workspace) else { return }
        update { record in
            record.projects[key]?.removeAll { $0 == sessionID }
            if record.projects[key]?.isEmpty == true { record.projects.removeValue(forKey: key) }
        }
    }

    func title(_ sessionID: String, fallback: String) -> String { record.names[sessionID] ?? fallback }

    func rename(_ sessionID: String, to name: String) {
        guard !sessionID.isEmpty else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update { record in
            if name.isEmpty { record.names.removeValue(forKey: sessionID) }
            else { record.names[sessionID] = name }
        }
    }

    /// Call only after a successful reconciliation. Ended terminals retained
    /// for their final scrollback are still included in `available`.
    func prune(available: Set<String>) {
        update { record in
            record.projects = record.projects.compactMapValues { ids in
                let kept = ids.filter { available.contains($0) }
                return kept.isEmpty ? nil : kept
            }
            record.names = record.names.filter { available.contains($0.key) }
        }
    }

    func refresh() {
        guard isOwnerCurrent(), let namespace else { return }
        let next = stored()[namespace] ?? Record()
        if next != record { record = next }
    }

    private func projectKey(peer: String, workspace: String) -> String? {
        guard isOwnerCurrent(), let scope, !peer.isEmpty, !workspace.isEmpty else { return nil }
        return WorkReferenceKey.folder(scope: scope, hostIdentity: peer, workspaceID: workspace)
    }

    private func stored() -> [String: Record] {
        defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([String: Record].self, from: $0)
        } ?? [:]
    }

    private func update(_ change: (inout Record) -> Void) {
        guard isOwnerCurrent(), let namespace else { return }
        // Merge from disk so another window's associations and other accounts
        // survive a write from a model that was mounted earlier.
        let all = stored()
        var next = all[namespace] ?? Record()
        change(&next)
        if next != record { record = next }
        guard all[namespace] != next, let encoded = try? JSONEncoder().encode(
            all.merging([namespace: next]) { _, fresh in fresh }
        ) else { return }
        defaults.set(encoded, forKey: storageKey)
    }
}
