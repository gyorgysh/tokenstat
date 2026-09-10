// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Labels and eligible identifiers only. Cache records contribute candidate
/// folders after host authorization, never permission to read those folders.
struct WorkSearchCatalog: Sendable {
    struct KnownFolder: Sendable {
        let reference: WorkReference
        let name: String
        let updatedAt: Date
    }

    let folders: [WorkSearchIndex.Folder: String]
    let machines: [String: String]
    let metadata: [WorkSearchIndex.Document]

    init(scope: WorkReference.Scope, linkedMachines: [String: String], allowedHosts: Set<String>,
         knownFolders: [KnownFolder], records: [CacheRecordMeta]) {
        machines = linkedMachines.filter { allowedHosts.contains($0.key) }
        var labels: [WorkSearchIndex.Folder: String] = [:]
        var documents: [WorkSearchIndex.Folder: WorkSearchIndex.Document] = [:]
        // Newest known label wins independently of caller iteration order.
        for folder in knownFolders.sorted(by: {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.name < $1.name
        }) {
            let ref = folder.reference
            guard ref.scope == scope, machines[ref.hostIdentity] != nil,
                  !ref.workspaceID.isEmpty, !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = WorkSearchIndex.Folder(hostIdentity: ref.hostIdentity, workspaceID: ref.workspaceID)
            guard labels[key] == nil else { continue }
            labels[key] = folder.name
            let reference = WorkReference(scope: scope, hostIdentity: ref.hostIdentity,
                                          workspaceID: ref.workspaceID, kind: .workspace, itemID: nil)
            documents[key] = .init(reference: reference, revision: "metadata", title: folder.name,
                text: "", folderName: folder.name, machineName: machines[ref.hostIdentity] ?? "",
                updatedAt: folder.updatedAt, partial: false)
        }
        let wireScope = WorkCache.scope(for: scope)
        for record in records {
            guard record.scope == wireScope,
                  let reference = WorkCache.reference(recordID: record.id, scope: scope),
                  WorkCache.matches(kind: record.kind, reference: reference),
                  reference.itemID == record.itemId, machines[reference.hostIdentity] != nil else { continue }
            let key = WorkSearchIndex.Folder(hostIdentity: reference.hostIdentity, workspaceID: reference.workspaceID)
            if labels[key] == nil { labels[key] = "Saved folder" }
        }
        folders = labels
        metadata = documents.values.sorted {
            let a = $0.reference
            let b = $1.reference
            return [a.hostIdentity, a.workspaceID].lexicographicallyPrecedes([b.hostIdentity, b.workspaceID])
        }
    }
}
