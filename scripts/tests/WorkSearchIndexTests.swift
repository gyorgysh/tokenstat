// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkSearchIndex.swift, WorkSearchText.swift and WorkReference.swift.
import Foundation

@main struct WorkSearchIndexTests {
    static func main() async throws {
        let scope = WorkReference.Scope.local(installationID: "test-installation")
        let folder = WorkSearchIndex.Folder(hostIdentity: "host-a", workspaceID: "folder-a")
        let index = WorkSearchIndex(scope: scope, folders: [folder])
        let reference = WorkReference(scope: scope, hostIdentity: "host-a", workspaceID: "folder-a",
                                      kind: .conversation, itemID: "chat-a")
        func document(_ reference: WorkReference, title: String = "Design", text: String = "Café layout") -> WorkSearchIndex.Document {
            .init(reference: reference, revision: "r1", title: title, text: text,
                  folderName: "App", machineName: "Studio", updatedAt: Date(timeIntervalSince1970: 1), partial: true)
        }
        var anchored = reference
        anchored.anchor = "user-s7"
        let load = await index.beginLoad(reference)!
        let inserted = await index.replace(load, documents: [document(anchored)])
        assert(inserted)
        let query = try WorkSearchQuery("café studio")
        let found = try await index.search(query)
        assert(found.total == 1 && found.hits[0].reference.anchor == "user-s7")
        assert(found.hits[0].partial && found.hits[0].revision == "r1")
        let missing = try await index.search(try WorkSearchQuery("café unavailable"))
        assert(missing.total == 0)
        let filtered = try await index.search(query, hosts: ["host-b"])
        assert(filtered.total == 0)

        // Revocation clears both visible text and a decryption already in flight.
        let pending = await index.beginLoad(reference)!
        await index.setAccess([])
        let refused = await index.replace(pending, documents: [document(anchored)])
        let revoked = try await index.search(query)
        assert(!refused && revoked.total == 0 && revoked.hits.isEmpty)
        await index.setAccess([folder])
        let replay = await index.replace(pending, documents: [document(anchored)])
        assert(!replay)
        let deletedLoad = await index.beginLoad(reference)!
        await index.remove(reference)
        let resurrected = await index.replace(deletedLoad, documents: [document(anchored)])
        assert(!resurrected)

        let old = await index.beginLoad(reference)!
        let new = await index.beginLoad(reference)!
        let oldAccepted = await index.replace(old, documents: [document(anchored)])
        let newAccepted = await index.replace(new, documents: [document(anchored, text: "New words")])
        assert(!oldAccepted && newAccepted)
        let oldText = try await index.search(query)
        assert(oldText.total == 0)

        let foreign = WorkReference(scope: .local(installationID: "other-installation"),
            hostIdentity: "host-a", workspaceID: "folder-a", kind: .conversation, itemID: "chat-a")
        let foreignLoad = await index.beginLoad(foreign)
        assert(foreignLoad == nil)
        let wrongContentLoad = await index.beginLoad(reference)!
        let foreignAccepted = await index.replace(wrongContentLoad, documents: [document(foreign)])
        assert(!foreignAccepted)

        // Equal ranks sort by stable identity, independent of insertion order.
        let groupedLoad = await index.beginLoad(reference)!
        let groupedAccepted = await index.replace(groupedLoad, documents: [
            document(reference, title: "Design"), document(anchored, title: "Design", text: "Design detail")
        ])
        assert(groupedAccepted)
        let grouped = try await index.search(try WorkSearchQuery("design"))
        assert(grouped.total == 1 && grouped.hits[0].reference.anchor == "user-s7")
        for number in (0..<205).reversed() {
            let row = WorkReference(scope: scope, hostIdentity: "host-a", workspaceID: "folder-a",
                kind: .conversation, itemID: String(format: "chat-%03d", number), anchor: "user-s1")
            let ticket = await index.beginLoad(row)!
            let accepted = await index.replace(ticket, documents: [document(row, title: "Needle", text: "body")])
            assert(accepted)
        }
        let many = try await index.search(try WorkSearchQuery("needle"), limit: 999)
        assert(many.total == 205 && many.hits.count == 50)
        assert(many.hits.first?.reference.itemID == "chat-000")
        assert(many.hits.last?.reference.itemID == "chat-049")
        var cursor = many.nextCursor
        var anchors = many.hits.compactMap(\.reference.itemID)
        while let next = cursor {
            let page = try await index.search(try WorkSearchQuery("needle"), cursor: next)
            assert(page.hits.count <= 50)
            anchors += page.hits.compactMap(\.reference.itemID)
            cursor = page.nextCursor
        }
        assert(anchors.count == 200 && Set(anchors).count == 200 && anchors.last == "chat-199")
        do {
            _ = try await index.search(try WorkSearchQuery("body"), cursor: many.nextCursor)
            assertionFailure("Cursor crossed query")
        } catch WorkSearchIndex.PageError.staleCursor {}
        do {
            _ = try await index.search(try WorkSearchQuery("needle"), hosts: ["host-a"], cursor: many.nextCursor)
            assertionFailure("Cursor crossed filter")
        } catch WorkSearchIndex.PageError.staleCursor {}
        await index.clear()
        do {
            _ = try await index.search(try WorkSearchQuery("needle"), cursor: many.nextCursor)
            assertionFailure("Cursor survived removal")
        } catch WorkSearchIndex.PageError.staleCursor {}
        let cleared = try await index.search(try WorkSearchQuery("needle"))
        assert(cleared.total == 0 && cleared.generation != many.generation)
        let oldPageCurrent = await index.isCurrent(generation: many.generation)
        let newPageCurrent = await index.isCurrent(generation: cleared.generation)
        assert(!oldPageCurrent && newPageCurrent, "Pending results must be revalidated after cache removal")
        let change = WorkReference(scope: scope, hostIdentity: "host-a", workspaceID: "folder-a",
                                   kind: .savedDiff, itemID: "snapshot")
        let changeLoad = await index.beginLoad(change)!
        _ = await index.replace(changeLoad, documents: [document(change)])
        let changeBefore = try await index.search(query, kinds: [.savedDiff])
        assert(changeBefore.total == 1)
        await index.retainSavedWork([])
        let changeAfter = try await index.search(query, kinds: [.savedDiff])
        assert(changeAfter.total == 0, "Listing reconciliation must remove evicted changes as well as conversations")
        print("Work search index: scope, revocation, stale loads, exact anchors, literal AND, stable order and result bound passed")
    }
}
