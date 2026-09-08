// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientRecentPlaces.swift.
import Foundation

@main struct ClientRecentPlacesTests {
    @MainActor static func main() {
        let suite = "ClientRecentPlacesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClientRecentPlaces(defaults: defaults)
        let alice = ClientRecentPlaces.Scope(host: "https://one.example", handle: "alice")!
        let bob = ClientRecentPlaces.Scope(host: "https://one.example", handle: "bob")!
        let otherHost = ClientRecentPlaces.Scope(host: "https://two.example", handle: "alice")!
        assert(store.places(in: alice).isEmpty)
        assert(ClientRecentPlaces.Scope(host: "host", handle: nil) == nil)
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
        let reloaded = ClientRecentPlaces(defaults: defaults)
        assert(reloaded.places(in: alice) == store.places(in: alice))
        record(40, name: "/Users/private/secret")
        record(41, name: "C:\\Users\\secret")
        record(42, name: "line\nprivate")
        assert(store.places(in: alice).prefix(3).allSatisfy { $0.workspaceName == "Workspace" })
        let data = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("client.recentPlaces.v1.") }.values.compactMap { $0 as? Data }.first!
        let json = String(decoding: data, as: UTF8.self)
        assert(!json.contains("secret") && !json.contains("private"))
        let records = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        assert(Set(records[0].keys) == ["id", "workspaceName", "openedAt"])
        store.record(in: bob, peer: "peer", workspaceID: nil, workspaceName: "", kind: .terminal, itemID: "tty")
        assert(store.places(in: bob).count == 1)
        store.record(in: bob, peer: "", workspaceID: "w", workspaceName: "W", kind: .workspace)
        store.record(in: bob, peer: "p", workspaceID: nil, workspaceName: "W", kind: .chat)
        assert(store.places(in: bob).count == 1)
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
