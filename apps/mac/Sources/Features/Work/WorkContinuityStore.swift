// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Small, device-local continuation metadata. Read-modify-write always reads
/// current storage so separate windows cannot overwrite each other's visits.
@MainActor
final class WorkContinuityStore {
    static let shared = WorkContinuityStore()
    private let defaults: UserDefaults
    private let key = "work.continuity.v1"
    private let capacity = 100

    private struct Visit: Codable {
        let reference: WorkReference
        let openedAt: Date
    }
    private struct Envelope: Codable {
        let version: Int
        var visits: [Visit]
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func lastConversation(scope: WorkReference.Scope, hostIdentity: String,
                          workspaceID: String) -> WorkReference? {
        read().first {
            $0.reference.scope == scope && $0.reference.hostIdentity == hostIdentity
                && $0.reference.workspaceID == workspaceID
                && $0.reference.kind == .conversation
        }?.reference
    }

    func remember(_ reference: WorkReference, at date: Date = Date()) {
        guard reference.kind == .conversation, let item = reference.itemID, !item.isEmpty,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty else { return }
        var visits = read().filter { !sameFolder($0.reference, reference) }
        visits.insert(Visit(reference: reference, openedAt: date), at: 0)
        write(Array(visits.prefix(capacity)))
    }

    func forget(scope: WorkReference.Scope, hostIdentity: String, workspaceID: String) {
        write(read().filter {
            !($0.reference.scope == scope && $0.reference.hostIdentity == hostIdentity
                && $0.reference.workspaceID == workspaceID)
        })
    }

    func remove(scope: WorkReference.Scope) {
        write(read().filter { $0.reference.scope != scope })
    }

    private func sameFolder(_ a: WorkReference, _ b: WorkReference) -> Bool {
        a.scope == b.scope && a.hostIdentity == b.hostIdentity && a.workspaceID == b.workspaceID
    }

    private func read() -> [Visit] {
        guard let data = defaults.data(forKey: key), data.count <= 256 * 1024,
              let stored = try? JSONDecoder().decode(Envelope.self, from: data),
              stored.version == 1 else { return [] }
        return Array(stored.visits.sorted { $0.openedAt > $1.openedAt }.prefix(capacity))
    }

    private func write(_ visits: [Visit]) {
        guard let data = try? JSONEncoder().encode(Envelope(version: 1, visits: visits)) else { return }
        defaults.set(data, forKey: key)
    }
}
