// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkDestinationResolver.swift
// WorkContinuityStore.swift WorkPlace.swift.
import Foundation

@main struct WorkPlaceTests {
    @MainActor static func main() {
        let name = "WorkPlaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkContinuityStore(defaults: defaults)
        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!
        let thisMac = "machine-a"
        let folders = ["local-folder", "other-local", "remote:phone:pocket", "remote:studio:site"]

        func folder(_ scope: WorkReference.Scope, host: String, id: String) -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: id,
                          kind: .workspace, itemID: nil)
        }
        func where_(_ place: WorkPlace?, scope: WorkReference.Scope?,
                    local: String? = thisMac,
                    among ids: [String] = folders) -> WorkPlaceRestoration.Destination? {
            WorkPlaceRestoration.destination(place: place, folderIDs: ids, scope: scope,
                                             localHostIdentity: local)
        }

        // A screen with no folder comes back whatever the account is doing.
        store.rememberPlace(.global("insights"))
        assert(WorkContinuityStore(defaults: defaults).place()?.globalSection == "insights")
        assert(where_(store.place(), scope: nil) == .global(section: "insights"))

        // A folder is named by its machine and that machine's own id for it,
        // and the shell's own id for it is rebuilt from the list.
        let local = WorkPlace.workspace(folder(alice, host: thisMac, id: "local-folder"),
                                        section: "chat")!
        assert(where_(local, scope: alice) == .workspace(folderID: "local-folder", section: "chat"))
        let remote = WorkPlace.workspace(folder(alice, host: "phone", id: "pocket"),
                                         section: "sessions")!
        assert(where_(remote, scope: alice)
            == .workspace(folderID: "remote:phone:pocket", section: "sessions"))

        // This machine's own folder opens before an account has loaded, and
        // for whoever is signed in. Another machine's folder is account work:
        // it waits for the scope, and never opens under a different one.
        assert(where_(local, scope: nil) != nil)
        assert(where_(local, scope: bob) != nil)
        assert(where_(remote, scope: nil) == nil)
        assert(where_(remote, scope: bob) == nil)

        // Without a verified identity for this machine, its own folders are
        // not identifiable, so nothing is opened by name alone.
        assert(where_(local, scope: alice, local: nil) == nil)
        assert(where_(local, scope: alice, local: "another-mac") == nil)

        // A folder that has been removed, or belongs to a machine that is not
        // on the tunnel, is not reopened.
        assert(where_(local, scope: alice, among: ["other-local"]) == nil)
        assert(where_(remote, scope: alice, among: ["remote:studio:pocket"]) == nil)
        assert(where_(nil, scope: alice) == nil)

        // Half a record is not a place.
        assert(WorkPlace.workspace(folder(alice, host: "", id: "x"), section: "chat") == nil)
        assert(WorkPlace.workspace(folder(alice, host: thisMac, id: "x"), section: "") == nil)
        assert(!WorkPlace(globalSection: "home", folder: folder(alice, host: thisMac, id: "x"),
                          folderSection: "chat", savedAt: Date()).isWellFormed)
        assert(!WorkPlace(savedAt: Date()).isWellFormed)

        // Storage: one record, replaced as the shell moves, dropped with the
        // account that owns it, and never trusted when it is damaged.
        store.rememberPlace(local)
        assert(store.place()?.folder?.workspaceID == "local-folder")
        store.remove(scope: bob)
        assert(store.place() != nil)
        store.remove(scope: alice)
        assert(store.place() == nil)
        store.rememberPlace(.global("home"))
        store.forgetPlace()
        assert(store.place() == nil)
        defaults.set(Data("corrupt".utf8), forKey: "work.place.v1")
        assert(store.place() == nil)

        // One restoration per process: a second window is a new place to work.
        WorkPlaceLaunch.resetForTesting()
        assert(WorkPlaceLaunch.claim())
        assert(!WorkPlaceLaunch.claim())

        print("Work place: rebuilt routes, account isolation, storage and one restoration passed")
    }
}
