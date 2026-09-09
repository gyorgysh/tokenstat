// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift WorkDestinationResolver.swift
// WorkContinuityStore.swift WorkPlace.swift.
import Foundation

@main struct WorkContinuityTests {
    @MainActor static func main() {
        let name = "WorkContinuityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkContinuityStore(defaults: defaults)
        let otherWindow = WorkContinuityStore(defaults: defaults)
        let alice = WorkReference.Scope.account(origin: "https://EXAMPLE.com:443/", handle: "alice")!
        assert(alice == .account(origin: "https://example.com", handle: "alice"))
        let bob = WorkReference.Scope.account(origin: "https://example.com", handle: "bob")!
        let local = WorkReference.Scope.local(installationID: "installation")
        func reference(_ scope: WorkReference.Scope, _ host: String, _ folder: String, _ chat: String) -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: folder,
                          kind: .conversation, itemID: chat)
        }
        let wire = #"{"scope":{"kind":"account","origin":"https://example.com","identity":"alice"},"hostIdentity":"host-a","workspaceId":"folder","kind":"conversation","itemId":"chat"}"#
        let decoded = try! JSONDecoder().decode(WorkReference.self, from: Data(wire.utf8))
        assert(decoded.workspaceID == "folder" && decoded.itemID == "chat")
        let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        assert(encoded["workspaceId"] as? String == "folder" && encoded["itemId"] as? String == "chat")
        let first = reference(alice, "host-a", "same-folder", "chat-a")
        store.remember(first)
        otherWindow.remember(reference(alice, "host-b", "same-folder", "chat-b"))
        otherWindow.remember(reference(bob, "host-a", "same-folder", "bob-chat"))
        otherWindow.remember(reference(local, "host-a", "same-folder", "local-chat"))
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "same-folder") == first)
        assert(store.lastConversation(scope: alice, hostIdentity: "host-b", workspaceID: "same-folder")?.itemID == "chat-b")
        assert(store.lastConversation(scope: bob, hostIdentity: "host-a", workspaceID: "same-folder")?.itemID == "bob-chat")
        assert(store.lastConversation(scope: local, hostIdentity: "host-a", workspaceID: "same-folder")?.itemID == "local-chat")
        // Home receives only this scope, even after another window records visits.
        assert(Set(store.recentConversations(scope: alice)) == Set([
            first, reference(alice, "host-b", "same-folder", "chat-b")
        ]))
        assert(store.recentConversations(scope: alice, limit: 1).count == 1)
        assert(store.recentConversations(scope: alice, limit: -1).isEmpty)
        assert(store.recentConversations(scope: bob).map(\.itemID) == ["bob-chat"])
        let reloaded = WorkContinuityStore(defaults: defaults)
        assert(reloaded.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "same-folder") == first)
        assert(WorkDestinationResolver.route(reference: first, currentScope: bob, localHostIdentity: "host-a") == nil)
        assert(WorkDestinationResolver.route(reference: first, currentScope: alice, localHostIdentity: "host-a")?.peer == nil)
        assert(WorkDestinationResolver.deletionPeer(folderID: "local-folder", currentPeer: "remote-host") == nil)
        assert(WorkDestinationResolver.deletionPeer(folderID: nil, currentPeer: "remote-host") == "remote-host")
        assert(WorkDestinationResolver.deletionPeer(folderID: "folder", currentFolderID: "folder", currentPeer: "phone-peer") == "phone-peer")
        assert(WorkDestinationResolver.deletionPeer(folderID: "folder", currentFolderID: "remote:peer:folder", currentPeer: "peer") == nil)
        assert(WorkDestinationResolver.deletionPeer(folderID: "remote:other:folder", currentPeer: "remote-host") == "other")
        assert(WorkDestinationResolver.route(folderID: "remote:other:folder").workspaceID == "folder")
        store.remove(scope: bob)
        assert(store.lastConversation(scope: bob, hostIdentity: "host-a", workspaceID: "same-folder") == nil)
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "same-folder") == first)
        store.forget(scope: alice, hostIdentity: "host-a", workspaceID: "same-folder")
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "same-folder") == nil)
        for n in 0..<120 {
            store.remember(reference(alice, "host-a", "folder-\(n)", "chat"), at: Date(timeIntervalSince1970: Double(n)))
        }
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "folder-0") == nil)
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "folder-119") != nil)
        assert(store.recentConversations(scope: alice).map(\.workspaceID)
            == ["same-folder", "folder-119", "folder-118", "folder-117"])
        defaults.set(Data("corrupt".utf8), forKey: "work.continuity.v1")
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "folder-119") == nil)
        defaults.set(try! JSONEncoder().encode(["ambiguous-folder": "old-chat"]), forKey: "chat.lastSelectedByFolder.v1")
        assert(store.lastConversation(scope: alice, hostIdentity: "host-a", workspaceID: "ambiguous-folder") == nil)
        print("Work continuity: routing, scope isolation, multiwindow persistence, eviction and corruption passed")
    }
}
