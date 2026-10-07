// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatListMutations.swift.
struct Row: Identifiable, Equatable { let id: String; let title: String }

@main struct ChatListMutationsTests {
    @MainActor static func main() {
        let edits = ChatListMutations<Row>()
        let a = Row(id: "a", title: "Old"), b = Row(id: "b", title: "Delete me")
        let renamed = Row(id: "a", title: "Renamed")
        let slow = edits.beginRead(owner: "account/mac/project")
        let foreign = edits.beginRead(owner: "account/other/project")
        edits.replace(renamed, owner: slow.owner)
        edits.remove(b.id, owner: slow.owner)
        let reconciled = edits.apply([a, b, b], read: slow, current: [renamed])
        precondition(reconciled == [renamed], "a pre-mutation reply cannot undo a rename or deletion")
        precondition(edits.apply([a, b], read: foreign, current: []) == [a, b], "host/project keys isolate writes")
        let fresh = edits.beginRead(owner: slow.owner)
        let remoteEdit = Row(id: "a", title: "Changed on another device")
        let current = edits.apply([remoteEdit], read: fresh, current: reconciled)
        precondition(current == [remoteEdit], "post-mutation reads remain authoritative")
        precondition(edits.apply([a, b], read: slow, current: current) == current,
            "an older read arriving after a newer read cannot regress metadata")
        for index in 0..<30 {
            let owner = "workspace-\(index)"
            let old = edits.beginRead(owner: owner)
            edits.remove("b", owner: owner)
            precondition(edits.apply([a,b], read: old, current: []) == [a])
            let newest = edits.beginRead(owner: owner)
            precondition(edits.apply([a], read: newest, current: [a]) == [a])
            precondition(edits.apply([a,b], read: old, current: [a]) == [a])
        }
        let beforeInsert = edits.beginRead(owner: "insert")
        edits.replace(a, owner: "insert")
        precondition(edits.apply([], read: beforeInsert, current: [a]) == [a])
        edits.removeAll()
        let newAccount = edits.beginRead(owner: slow.owner)
        precondition(edits.apply([a,b], read: newAccount, current: []) == [a,b])
        print("ChatListMutationsTests passed: rename, delete, late replies, fresh authority, isolation and reset.")
    }
}
