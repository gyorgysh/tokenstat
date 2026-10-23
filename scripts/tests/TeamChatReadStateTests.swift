// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamChatReadState.swift TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

@main struct TeamChatReadStateTests {
    @MainActor static func main() throws {
        let suite = "team-read-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = TeamAccountOwner(scope: .account(origin: "https://accounts.example.test", handle: "example")!, generation: 1, session: "one", personId: "person-one")
        let repository = TeamRepository(id: "repo_one", organizationId: "org_one", name: "Example project", role: .contributor, revision: 1, createdAt: "")
        let checkout = TeamCheckout(id: "checkout_one", organizationId: "org_one", repositoryId: "repo_one", publisherId: "publisher", machineId: "machine", hostKey: "host-one", revision: 1, createdAt: "")
        var share = TeamSharedChat(id: "share_one", checkoutId: checkout.id, revision: 1, createdAt: "", title: "A private display title", lastMessageAtMs: 100)
        let state = TeamChatReadState(defaults: defaults)
        precondition(!state.isUnread(share, repository: repository, checkout: checkout), "Signed-out state exposed another account's activity")
        state.bind(to: owner)
        precondition(state.isUnread(share, repository: repository, checkout: checkout), "A newly discovered chat needs an activity badge")
        state.markRead(share, repository: repository, checkout: checkout, through: 100)
        precondition(!state.isUnread(share, repository: repository, checkout: checkout))
        share.lastMessageAtMs = 101
        precondition(state.isUnread(share, repository: repository, checkout: checkout), "A new remote comment was hidden")
        state.markRead(share, repository: repository, checkout: checkout, through: 103)
        share.lastMessageAtMs = 102
        precondition(!state.isUnread(share, repository: repository, checkout: checkout), "An older response moved the read position backward")
        let restored = TeamChatReadState(defaults: defaults)
        restored.bind(to: owner)
        precondition(!restored.isUnread(share, repository: repository, checkout: checkout), "Relaunch lost a read position")
        let other = TeamAccountOwner(scope: owner.scope, generation: 2, session: "two", personId: "person-two")
        restored.bind(to: other)
        precondition(restored.isUnread(share, repository: repository, checkout: checkout), "Read positions crossed verified people under the same display handle")
        restored.bind(to: owner)
        let separateHost = TeamCheckout(id: checkout.id, organizationId: checkout.organizationId, repositoryId: checkout.repositoryId, publisherId: checkout.publisherId, machineId: checkout.machineId, hostKey: "other-host", revision: 1, createdAt: "")
        precondition(restored.isUnread(share, repository: repository, checkout: separateHost), "Read positions crossed publishing hosts")
        let empty = TeamSharedChat(id: "empty", checkoutId: checkout.id, revision: 1, createdAt: "")
        restored.markRead(empty, repository: repository, checkout: checkout, through: nil)
        precondition(!restored.isUnread(empty, repository: repository, checkout: checkout), "An empty shared chat stayed permanently new")
        let secondWindow = TeamChatReadState(defaults: defaults)
        secondWindow.bind(to: owner)
        let another = TeamSharedChat(id: "another", checkoutId: checkout.id, revision: 1, createdAt: "")
        restored.markRead(another, repository: repository, checkout: checkout, through: nil)
        var newer = share; newer.lastMessageAtMs = 104
        secondWindow.markRead(newer, repository: repository, checkout: checkout, through: 104)
        let reopened = TeamChatReadState(defaults: defaults); reopened.bind(to: owner)
        precondition(reopened.hasRead(another, repository: repository, checkout: checkout), "One window overwrote another window's read positions")
        restored.refresh()
        precondition(!restored.isUnread(newer, repository: repository, checkout: checkout), "Refreshing did not merge another window's newer read position")
        let persisted = defaults.dictionaryRepresentation().description
        precondition(!persisted.contains("A private display title") && !persisted.contains("share_one") && !persisted.contains("person-one"), "Read state stored cleartext chat metadata")
        print("Team shared-chat activity persistence and account isolation passed")
    }
}
