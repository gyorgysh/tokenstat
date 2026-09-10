// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit

/// An explicitly viewed snapshot. Source text is sealed for reading; only
/// commit metadata and file names enter the disposable search index.
struct WorkViewedChange: Codable, Sendable, Identifiable {
    let reference: WorkReference
    let title: String
    let capturedAt: Date
    let revision: String
    let commit: CommitDetail?
    let diff: FileDiff?
    var id: WorkReference { reference }
    var diffs: [FileDiff] { commit?.diffs ?? diff.map { [$0] } ?? [] }

    struct Record: Decodable, Sendable {
        let scope: String
        let id: String
        let kind: String
        let itemId: String
        let revision: String?
        let payload: WorkViewedChange

        func matches(_ reference: WorkReference) -> Bool {
            scope == WorkCache.scope(for: reference.scope)
                && id == WorkCache.recordID(for: reference) && kind == "diff"
                && itemId == reference.itemID && revision == payload.revision
                && payload.reference == reference && payload.valid
        }
    }

    var valid: Bool {
        switch reference.kind {
        case .commit: commit != nil && diff == nil && commit?.id == reference.itemID
        case .savedDiff: diff != nil && commit == nil && revision == reference.itemID
        default: false
        }
    }

    func documents(folderName: String, machineName: String) -> [WorkSearchIndex.Document] {
        guard valid else { return [] }
        let metadata = commit.map { [$0.body, $0.author, $0.id] + $0.files.map(\.path) }
            ?? diffs.map(\.path)
        return [.init(reference: reference, revision: revision, title: title,
                      text: metadata.joined(separator: "\n"), folderName: folderName,
                      machineName: machineName, updatedAt: capturedAt, partial: false)]
    }

    @MainActor
    static func owner(folderID: String, peer: String? = nil) -> WorkReference? {
        guard let scope = WorkSessionContext.shared.scope else { return nil }
        let route = WorkDestinationResolver.route(folderID: folderID, explicitPeer: peer)
        guard let host = route.peer ?? WorkSessionContext.shared.localHostIdentity else { return nil }
        return WorkReference(scope: scope, hostIdentity: host, workspaceID: route.workspaceID,
                             kind: .workspace, itemID: nil)
    }

    @MainActor
    static func save(owner: WorkReference?, commit: CommitDetail? = nil, diff: FileDiff? = nil) async {
        guard let owner, WorkCacheAccess.canSave(owner),
              !Task.isCancelled, WorkCacheSettings.shared.saves(owner),
              (commit != nil) != (diff != nil) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let source = commit.flatMap({ try? encoder.encode($0) }) ?? diff.flatMap({ try? encoder.encode($0) }) else { return }
        let revision = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let reference = WorkReference(scope: owner.scope, hostIdentity: owner.hostIdentity,
            workspaceID: owner.workspaceID, kind: commit == nil ? .savedDiff : .commit,
            itemID: commit?.id ?? revision)
        let copy = Self(reference: reference, title: commit?.subject ?? diff?.path ?? "Changes",
                        capturedAt: Date(), revision: revision, commit: commit, diff: diff)
        let scope = WorkCache.scope(for: owner.scope)
        guard let id = WorkCache.recordID(for: reference),
              let key = WorkCacheKey.key(for: scope),
              let data = try? encoder.encode(copy), data.count <= 8 * 1024 * 1024,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        _ = try? await Bridge.cachePut(key: WorkCacheKey.encoded(key), scope: scope,
            id: id, kind: "diff", itemId: reference.itemID ?? revision, revision: revision, payload: payload)
    }
}
