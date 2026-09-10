// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Device-local navigation identifiers. No folder snapshots, commands, paths,
/// conversation titles or draft text are serialized into navigation storage.
struct WorkMobileRoute: Codable, Hashable, Identifiable, Sendable {
    var id: Self { self }
    let scope: WorkReference.Scope
    var tab: String
    var reference: WorkReference?
    var section: String?

    var isValid: Bool {
        guard scope.kind == .account,
              WorkReference.Scope.account(origin: scope.origin, handle: scope.identity) == scope,
              ["home", "workspaces", "insights", "machines", "ssh"].contains(tab) else { return false }
        guard let reference else { return section == nil }
        guard reference.scope == scope, !reference.hostIdentity.isEmpty,
              !reference.workspaceID.isEmpty,
              [reference.hostIdentity, reference.workspaceID, reference.itemID, reference.anchor]
                .compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { return false }
        switch reference.kind {
        case .workspace:
            return reference.itemID == nil && reference.anchor == nil
                && (section == nil || section.map { Self.sections.contains($0) } == true)
        case .conversation:
            return reference.itemID != nil && section == "chat"
        case .terminal:
            return reference.itemID != nil && section == "sessions"
        case .commit, .savedDiff:
            return false
        }
    }

    private static let sections: Set<String> = [
        "sessions", "chat", "changes", "history", "pulls", "todo", "notes",
        "workflows", "automations", "files", "browser"
    ]
}

@MainActor
final class WorkMobileRouteStore {
    static let shared = WorkMobileRouteStore()
    private let defaults: UserDefaults
    private let key = "work.mobileRoute.v1"
    private struct Envelope: Codable { let version: Int; let route: WorkMobileRoute }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func save(_ route: WorkMobileRoute) -> Bool {
        guard route.isValid,
              let data = try? JSONEncoder().encode(Envelope(version: 1, route: route)),
              data.count <= 32 * 1024 else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    func route(for scope: WorkReference.Scope) -> WorkMobileRoute? {
        guard let data = defaults.data(forKey: key), data.count <= 32 * 1024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.route.isValid,
              envelope.route.scope == scope else { return nil }
        return envelope.route
    }

    func clear() { defaults.removeObject(forKey: key) }
}

/// A verified account may restore once, unless a person or notification has
/// already chosen somewhere to go. Capturing a ticket before awaiting account
/// verification prevents a late completion from replacing that newer choice.
@MainActor
final class WorkMobileRouteLaunch {
    private(set) var generation: UInt64 = 0
    private var claimed = false

    func navigationChanged() { generation &+= 1 }

    func claim(ticket: UInt64) -> Bool {
        guard !claimed, ticket == generation else { return false }
        claimed = true
        return true
    }
}
