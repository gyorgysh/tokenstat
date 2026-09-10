// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkSearchCache.swift WorkSearchIndex.swift WorkSearchText.swift WorkReference.swift WorkCache.swift.
import Foundation

@main struct WorkSearchCacheTests {
    static func main() async throws {
        let cache = WorkSearchCache()
        let a = WorkReference.Scope.local(installationID: "a|with-separator")
        let b = WorkReference.Scope.local(installationID: "b")
        let folder = WorkSearchIndex.Folder(hostIdentity: "host", workspaceID: "folder")
        let sa = await cache.subscribe(scope: a, folders: [folder])
        let sb = await cache.subscribe(scope: b, folders: [folder])
        func reference(_ scope: WorkReference.Scope, _ id: String = "chat") -> WorkReference {
            .init(scope: scope, hostIdentity: "host", workspaceID: "folder", kind: .conversation, itemID: id)
        }
        func document(_ ref: WorkReference) -> WorkSearchIndex.Document {
            .init(reference: ref, revision: "r1", title: "Needle", text: "Saved words",
                  folderName: "Folder", machineName: "Host", updatedAt: Date(), partial: true)
        }
        func insert(_ sub: WorkSearchCache.Subscription, _ ref: WorkReference) async {
            let read = await cache.beginRead(sub, reference: ref)!
            let accepted = await cache.finishRead(read, documents: [document(ref)])
            assert(accepted)
        }
        let query = try WorkSearchQuery("needle")
        await insert(sa, reference(a))
        await insert(sa, reference(a, "preserved"))
        await insert(sb, reference(b))
        let pending = await cache.beginRead(sa, reference: reference(a))!
        let mutation = await cache.beginMutation()
        let during = await cache.beginRead(sb, reference: reference(b))
        assert(during == nil)
        let late = await cache.finishRead(pending, documents: [document(reference(a))])
        assert(!late)
        await cache.finishMutation(mutation, scope: WorkCache.scope(for: b),
            changedIDs: [WorkCache.recordID(for: reference(b))!],
            evicted: [WorkCache.scope(for: a) + "|" + WorkCache.recordID(for: reference(a))!])
        let afterA = try await sa.index.search(query)
        let afterB = try await sb.index.search(query)
        assert(afterA.total == 1 && afterA.hits[0].reference.itemID == "preserved")
        assert(afterB.total == 0)
        let stillLate = await cache.finishRead(pending, documents: [document(reference(a))])
        assert(!stillLate)
        await insert(sb, reference(b))
        let one = await cache.beginMutation()
        let two = await cache.beginMutation()
        await cache.finishMutation(one, scope: WorkCache.scope(for: a), cleared: true)
        let overlapping = await cache.beginRead(sb, reference: reference(b))
        assert(overlapping == nil)
        await cache.finishMutation(two, scope: WorkCache.scope(for: a))
        let preservedB = try await sb.index.search(query)
        let clearedA = try await sa.index.search(query)
        assert(preservedB.total == 1 && clearedA.total == 0)
        let failed = await cache.beginMutation()
        await cache.finishMutation(failed, scope: WorkCache.scope(for: a), uncertain: true)
        let uncertainB = try await sb.index.search(query)
        assert(uncertainB.total == 0)
        await insert(sa, reference(a))
        await insert(sb, reference(b))
        let revokedRead = await cache.beginRead(sa, reference: reference(a))!
        await cache.revokeHost("host", scope: a)
        let revokedLate = await cache.finishRead(revokedRead, documents: [document(reference(a))])
        let denied = try await sa.index.search(query)
        let otherAccount = try await sb.index.search(query)
        assert(!revokedLate && denied.total == 0 && otherAccount.total == 1)
        let newDeniedRead = await cache.beginRead(sa, reference: reference(a))
        assert(newDeniedRead == nil)
        let abandoned = await cache.beginRead(sb, reference: reference(b))!
        await cache.unsubscribe(sb)
        let afterDismiss = await cache.finishRead(abandoned, documents: [document(reference(b))])
        let dismissed = try await sb.index.search(query)
        assert(!afterDismiss && dismissed.total == 0)
        print("Search cache: mutation barriers, cross-scope eviction, precise retention, overlap, uncertain replies and disposal passed")
    }
}
