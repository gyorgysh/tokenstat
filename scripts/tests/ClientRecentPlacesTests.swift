// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientRecentPlaces.swift WorkReference.swift.
import Foundation

@main struct ClientRecentPlacesTests {
    @MainActor static func main() {
        let suite = "ClientRecentPlacesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClientRecentPlaces(defaults: defaults)
        let alice = ClientRecentPlaces.Scope(host: "https://one.example", handle: "alice", id: "acc_alice")!
        let bob = ClientRecentPlaces.Scope(host: "https://one.example", handle: "bob", id: "acc_bob")!
        let otherHost = ClientRecentPlaces.Scope(host: "https://two.example", handle: "alice", id: "acc_alice")!
        // A handleless account keeps history under the server's id for it.
        let unclaimed = ClientRecentPlaces.Scope(host: "https://one.example", handle: nil, id: "acc_new")!
        assert(unclaimed.identity == "acc_new" && alice.identity == "alice")
        assert(store.places(in: alice).isEmpty)
        assert(store.places(in: unclaimed).isEmpty)
        store.record(in: unclaimed, peer: "peer", workspaceID: "workspace", workspaceName: "Garden",
                     kind: .chat, itemID: "chat-1")
        assert(store.places(in: unclaimed).count == 1)
        assert(store.places(in: alice).isEmpty)
        assert(ClientRecentPlaces.Scope(host: "host", handle: nil, id: nil) == nil)
        assert(ClientRecentPlaces.Scope(host: "", handle: "alice", id: nil) == nil)
        func record(_ n: Int, scope: ClientRecentPlaces.Scope? = alice, name: String = "Garden") {
            store.record(in: scope, peer: "peer", workspaceID: "workspace", workspaceName: name,
                         kind: .chat, itemID: "chat-\(n)", at: Date(timeIntervalSince1970: Double(n)))
        }
        record(1)
        assert(store.places(in: bob).isEmpty && store.places(in: otherHost).isEmpty)
        assert(store.places(in: nil).isEmpty)
        record(2, scope: nil)
        assert(store.places(in: alice).count == 1)
        for n in 2...25 { record(n) }
        assert(store.places(in: alice).count == 20)
        assert(store.places(in: alice).first?.id.itemID == "chat-25")
        store.record(in: alice, peer: "peer", workspaceID: "workspace", workspaceName: "Renamed",
                     kind: .chat, itemID: "chat-6", at: Date(timeIntervalSince1970: 30))
        assert(store.places(in: alice).first?.workspaceName == "Renamed")
        assert(store.places(in: alice).count == 20)
        let onePerRepository = store.continuePlaces(in: alice)
        assert(onePerRepository.count == 1 && onePerRepository[0].id.itemID == "chat-6")
        assert(store.places(in: alice).count == 20, "Continue must not delete older chat history")
        let reloaded = ClientRecentPlaces(defaults: defaults)
        assert(reloaded.places(in: alice) == store.places(in: alice))
        record(40, name: "/Users/private/secret")
        record(41, name: "C:\\Users\\secret")
        record(42, name: "line\nprivate")
        assert(store.places(in: alice).prefix(3).allSatisfy { $0.workspaceName == "Repository" })
        let data = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("client.recentPlaces.v1.") }.values.compactMap { $0 as? Data }.first!
        let json = String(decoding: data, as: UTF8.self)
        assert(!json.contains("secret") && !json.contains("private"))
        let records = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        assert(Set(records[0].keys) == ["id", "workspaceName", "openedAt"])
        store.record(in: bob, peer: "peer", workspaceID: nil, workspaceName: "", kind: .terminal, itemID: "tty")
        assert(store.places(in: bob).count == 1)
        // Real hosts may identify workspaces by their canonical paths, on
        // either platform. Preserve the ID for routing without displaying it.
        store.record(in: bob, peer: "peer", workspaceID: "/Users/example/project", workspaceName: "Project",
                     kind: .chat, itemID: "unix-chat")
        store.record(in: bob, peer: "peer", workspaceID: "C:\\Users\\example\\project", workspaceName: "Project",
                     kind: .chat, itemID: "windows-chat")
        let pathPlaces = ClientRecentPlaces(defaults: defaults).places(in: bob)
        assert(pathPlaces.contains { $0.id.workspaceID == "/Users/example/project" && $0.id.itemID == "unix-chat" })
        assert(pathPlaces.contains { $0.id.workspaceID == "C:\\Users\\example\\project" && $0.id.itemID == "windows-chat" })
        assert(pathPlaces.filter { $0.id.kind == .chat }.allSatisfy { $0.workspaceName == "Project" })
        assert(store.continuePlaces(in: bob).map(\.id.itemID) == ["windows-chat"],
               "Home offers only the latest chat when there is no recent project")
        store.record(in: otherHost, peer: "peer", workspaceID: "project", workspaceName: "Project",
                     kind: .workspace, at: Date(timeIntervalSince1970: 10))
        store.record(in: otherHost, peer: "peer", workspaceID: "project", workspaceName: "Project",
                     kind: .chat, itemID: "chat", at: Date(timeIntervalSince1970: 11))
        store.record(in: otherHost, peer: "peer", workspaceID: "project", workspaceName: "Project",
                     kind: .terminal, itemID: "terminal", at: Date(timeIntervalSince1970: 12))
        assert(store.continuePlaces(in: otherHost).map(\.id.kind) == [.chat, .workspace],
               "Home keeps the project and chat instead of a newer terminal")
        store.remove(in: alice, peer: "peer", workspaceID: nil, kind: .terminal, itemID: "tty")
        assert(store.places(in: bob).contains { $0.id.itemID == "tty" }, "another account cannot remove it")
        store.remove(in: bob, peer: "peer", workspaceID: nil, kind: .terminal, itemID: "tty")
        assert(!store.places(in: bob).contains { $0.id.itemID == "tty" }, "closed terminal leaves Continue")
        assert(store.places(in: bob).count == 2, "chat history survives terminal removal")
        assert(!store.places(in: alice).contains { $0.id.itemID == "unix-chat" })
        // A busy device still offers its last chat after many other places.
        for n in 1...25 {
            store.record(in: unclaimed, peer: "peer", workspaceID: "folder-\(n)",
                         workspaceName: "Garden", kind: .workspace,
                         at: Date(timeIntervalSince1970: Date().timeIntervalSince1970 + Double(n)))
        }
        let continued = store.continuePlaces(in: unclaimed)
        assert(continued.count == 2 && continued.contains { $0.id.itemID == "chat-1" })
        assert(store.places(in: unclaimed).count == ClientRecentPlaces.capacity)
        assert(store.continuePlaces(in: alice, limit: 0).isEmpty)
        assert(store.continuePlaces(in: nil).isEmpty)
        store.record(in: bob, peer: "", workspaceID: "w", workspaceName: "W", kind: .workspace)
        store.record(in: bob, peer: "p", workspaceID: nil, workspaceName: "W", kind: .chat)
        store.record(in: bob, peer: "p", workspaceID: "/bad\npath", workspaceName: "W", kind: .workspace)
        assert(store.places(in: bob).count == 2)
        // A damaged record must not prevent opening Home or another account.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("client.recentPlaces.v1.") {
            defaults.set(Data("broken".utf8), forKey: key)
        }
        assert(reloaded.places(in: alice).isEmpty)
        record(50)
        assert(store.places(in: alice).count == 1)
        print("ClientRecentPlaces: persistence, recency, capacity, account isolation, privacy and corruption passed")
    }
}
