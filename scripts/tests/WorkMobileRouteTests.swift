// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkMobileRoute.swift.
import Foundation

@main struct WorkMobileRouteTests {
    @MainActor static func main() {
        let name = "WorkMobileRouteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkMobileRouteStore(defaults: defaults)
        let alice = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!
        let chat = WorkReference(scope: alice, hostIdentity: "host-a", workspaceID: "folder-a",
                                 kind: .conversation, itemID: "chat-a", anchor: "user-s12")
        let route = WorkMobileRoute(scope: alice, tab: "home", reference: chat, section: "chat")
        assert(store.save(route))
        assert(WorkMobileRouteStore(defaults: defaults).route(for: alice) == route)
        assert(store.route(for: bob) == nil)
        var invalid = route
        invalid.section = "sessions"
        assert(!store.save(invalid))
        invalid = route
        invalid.reference = WorkReference(scope: bob, hostIdentity: "host-a", workspaceID: "folder-a",
                                          kind: .conversation, itemID: "chat-a")
        assert(!store.save(invalid))
        invalid = route
        invalid.tab = "unknown-future-tab"
        assert(!store.save(invalid))
        assert(store.route(for: alice) == route) // Invalid writes preserve last good route.
        let home = WorkMobileRoute(scope: alice, tab: "home")
        assert(store.save(home) && store.route(for: alice) == home)
        let folder = WorkReference(scope: alice, hostIdentity: "host-a", workspaceID: "folder-a",
                                   kind: .workspace, itemID: nil)
        let overview = WorkMobileRoute(scope: alice, tab: "workspaces", reference: folder)
        assert(store.save(overview) && store.route(for: alice) == overview)
        assert(store.save(WorkMobileRoute(scope: alice, tab: "workspaces", reference: folder, section: "files")))
        let terminal = WorkReference(scope: alice, hostIdentity: "host-a", workspaceID: "folder-a",
                                     kind: .terminal, itemID: "existing-session")
        assert(store.save(WorkMobileRoute(scope: alice, tab: "workspaces", reference: terminal, section: "sessions")))
        assert(store.route(for: alice)?.reference?.itemID == "existing-session")
        let wrongVersion = #"{"version":2,"route":{"scope":{"kind":"account","origin":"https://example.com","identity":"alice"},"tab":"home"}}"#
        defaults.set(Data(wrongVersion.utf8), forKey: "work.mobileRoute.v1")
        assert(store.route(for: alice) == nil)
        defaults.set(Data("broken".utf8), forKey: "work.mobileRoute.v1")
        assert(store.route(for: alice) == nil)
        defaults.set(Data(repeating: 0, count: 33 * 1024), forKey: "work.mobileRoute.v1")
        assert(store.route(for: alice) == nil)
        assert(store.save(route))
        store.clear()
        assert(store.route(for: alice) == nil)
        let launch = WorkMobileRouteLaunch()
        let ticket = launch.generation
        launch.navigationChanged()
        assert(!launch.claim(ticket: ticket))
        let cold = WorkMobileRouteLaunch()
        assert(cold.claim(ticket: cold.generation))
        assert(!cold.claim(ticket: cold.generation))
        print("Mobile route: exact identifiers, account isolation, validation, corruption and late restoration arbitration passed")
    }
}
