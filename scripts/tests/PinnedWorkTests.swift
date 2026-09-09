// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with PinnedWork.swift WorkReference.swift WorkCache.swift.
import Foundation

@main struct PinnedWorkTests {
    @MainActor static func main() {
        let name = "PinnedWorkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PinnedWorkStore(defaults: defaults)
        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!

        func conversation(_ scope: WorkReference.Scope, host: String, folder: String, id: String) -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: folder,
                          kind: .conversation, itemID: id)
        }
        func folder(_ scope: WorkReference.Scope, host: String, id: String) -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: id,
                          kind: .workspace, itemID: nil)
        }

        // Empty until pinned, and pinning names the work.
        assert(store.pins(in: alice).isEmpty)
        let first = conversation(alice, host: "mac", folder: "site", id: "c1")
        assert(store.pin(first, label: "Launch plan", folderName: "Site"))
        assert(store.isPinned(first))
        assert(store.pins(in: alice).map(\.label) == ["Launch plan"])

        // Re-pinning updates the label and keeps one row.
        assert(store.pin(first, label: "Launch plan v2", folderName: "Site"))
        assert(store.pins(in: alice).count == 1)
        assert(store.pins(in: alice).first?.label == "Launch plan v2")

        // The same conversation id on another machine is another pin.
        let twin = conversation(alice, host: "phone", folder: "site", id: "c1")
        assert(store.pin(twin, label: "Phone thread", folderName: "Site"))
        assert(store.pins(in: alice).count == 2)
        assert(store.isPinned(twin))

        // Folders pin without an item; a workspace with an item id is refused.
        let home = folder(alice, host: "mac", id: "site")
        assert(store.pin(home, label: "Site", folderName: "Site"))
        let badFolder = WorkReference(scope: alice, hostIdentity: "mac", workspaceID: "site",
                                      kind: .workspace, itemID: "c1")
        assert(!store.pin(badFolder, label: "Nope", folderName: "Site"))

        // Eight pins, and the ninth is refused rather than evicting one.
        for index in 0..<5 {
            assert(store.pin(conversation(alice, host: "mac", folder: "site", id: "extra-\(index)"),
                             label: "Extra \(index)", folderName: "Site"))
        }
        assert(store.pins(in: alice).count == 8)
        assert(!store.pin(conversation(alice, host: "mac", folder: "site", id: "ninth"),
                          label: "Ninth", folderName: "Site"))
        assert(store.pins(in: alice).count == 8)

        // Unpinning frees the shelf.
        store.unpin(first)
        assert(!store.isPinned(first))
        assert(store.pins(in: alice).count == 7)
        assert(store.pin(conversation(alice, host: "mac", folder: "site", id: "ninth"),
                         label: "Ninth", folderName: "Site"))

        // Another account sees none of this.
        assert(store.pins(in: bob).isEmpty)
        assert(!store.isPinned(first))
        assert(store.pin(conversation(bob, host: "mac", folder: "site", id: "c1"),
                         label: "Bob's", folderName: "Site"))
        assert(store.pins(in: bob).count == 1)
        assert(store.pins(in: alice).count == 8)

        // A hostile label is replaced, never stored.
        assert(store.pin(conversation(bob, host: "mac", folder: "site", id: "evil"),
                         label: "a/b\\c", folderName: "Site"))
        assert(store.pins(in: bob).contains { $0.label == "Pinned work" })

        // The scope pins file under: the signed-in account, never whoever
        // signs in next.
        assert(PinnedWorkStore.scope(host: "https://example.com", handle: "alice") == alice)
        assert(PinnedWorkStore.scope(host: "https://example.com", handle: nil) == nil)
        assert(PinnedWorkStore.scope(host: "https://example.com", handle: "") == nil)
        assert(PinnedWorkStore.scope(host: "", handle: "alice") == nil)

        // Corruption reads as empty, not a crash.
        defaults.set(Data("not pins".utf8), forKey: "pinned.work.v1.\(WorkCache.scope(for: bob))")
        assert(PinnedWorkStore(defaults: defaults).pins(in: bob).isEmpty)

        print("PinnedWorkTests passed")
    }
}
