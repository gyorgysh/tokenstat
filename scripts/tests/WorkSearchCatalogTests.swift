// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkSearchCatalog.swift WorkSearchIndex.swift WorkSearchText.swift WorkReference.swift WorkCache.swift.
import Foundation
struct CacheRecordMeta: Sendable { let scope: String; let id: String; let kind: String; let itemId: String }
@main struct WorkSearchCatalogTests {
    static func main() {
        let scope = WorkReference.Scope.local(installationID: "scope")
        func ref(_ host: String, folder: String = "folder") -> WorkReference {
            .init(scope: scope, hostIdentity: host, workspaceID: folder, kind: .conversation, itemID: "chat")
        }
        func record(_ host: String, folder: String = "folder") -> CacheRecordMeta {
            .init(scope: WorkCache.scope(for: scope), id: WorkCache.recordID(for: ref(host, folder: folder))!,
                  kind: "conversation", itemId: "chat")
        }
        let known: [WorkSearchCatalog.KnownFolder] = [
            .init(reference: ref("yes"), name: "Old", updatedAt: Date(timeIntervalSince1970: 1)),
            .init(reference: ref("yes"), name: "New", updatedAt: Date(timeIntervalSince1970: 2)),
            .init(reference: ref("denied"), name: "Private", updatedAt: Date())
        ]
        let catalog = WorkSearchCatalog(scope: scope,
            linkedMachines: ["yes": "Computer", "denied": "Denied", "unknown": "Unknown"],
            allowedHosts: ["yes", "removed"], knownFolders: known,
            records: [record("yes"), record("yes", folder: "unnamed"), record("denied"), record("unknown"), record("removed")])
        assert(catalog.machines == ["yes": "Computer"])
        assert(catalog.folders.count == 2 && catalog.metadata.count == 1)
        assert(catalog.metadata[0].title == "New" && catalog.metadata[0].reference.kind == .workspace)
        assert(catalog.metadata[0].reference.itemID == nil)
        assert(catalog.folders[.init(hostIdentity: "yes", workspaceID: "unnamed")] == "Saved folder")
        let empty = WorkSearchCatalog(scope: scope, linkedMachines: ["yes": "Computer"],
            allowedHosts: [], knownFolders: known, records: [record("yes")])
        assert(empty.folders.isEmpty && empty.metadata.isEmpty)
        print("Search catalog: independent authorization, linked hosts, newest labels, canonical folder metadata and unlabeled copies passed")
    }
}
