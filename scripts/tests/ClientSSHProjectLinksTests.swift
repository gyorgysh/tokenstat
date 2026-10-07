// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientSSHProjectLinks.swift WorkReference.swift.
import Foundation
import Observation

@main struct ClientSSHProjectLinksTests {
    @MainActor private final class Updates { var count = 0 }
    @MainActor static func main() {
        let suite = "ClientSSHProjectLinksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WorkReference.Scope.account(origin: "https://example.test", handle: "first")!
        let other = WorkReference.Scope.account(origin: "https://example.test", handle: "other")!
        let links = ClientSSHProjectLinks(scope: first, defaults: defaults)
        links.attach("one", peer: "host|one", workspace: "project")
        links.attach("two", peer: "host|one", workspace: "project")
        links.attach("one", peer: "host|one", workspace: "project")
        precondition(links.sessions(peer: "host|one", workspace: "project") == ["one", "two"])
        precondition(links.sessions(peer: "host", workspace: "one|project").isEmpty)
        precondition(links.sessions(peer: "host|one", workspace: "different").isEmpty)

        let updates = Updates()
        withObservationTracking {
            _ = links.sessions(peer: "host|one", workspace: "project")
        } onChange: { MainActor.assumeIsolated { updates.count += 1 } }
        for _ in 0..<30 { links.attach("one", peer: "host|one", workspace: "project") }
        precondition(updates.count == 0, "Unchanged project links republished")

        let secondWindow = ClientSSHProjectLinks(scope: first, defaults: defaults)
        links.attach("three", peer: "host|one", workspace: "project")
        secondWindow.attach("four", peer: "host|one", workspace: "project")
        links.refresh()
        precondition(links.sessions(peer: "host|one", workspace: "project") == ["one", "two", "three", "four"], "Another window's links were overwritten")

        let otherAccount = ClientSSHProjectLinks(scope: other, defaults: defaults)
        precondition(otherAccount.sessions(peer: "host|one", workspace: "project").isEmpty)
        otherAccount.attach("foreign", peer: "host|one", workspace: "project")
        otherAccount.rename("one", to: "Other account")
        links.rename("one", to: "  Logs  ")
        precondition(links.title("one", fallback: "Server") == "Logs")
        precondition(otherAccount.title("one", fallback: "Server") == "Other account")
        links.detach("one", peer: "host|one", workspace: "project")
        precondition(links.title("one", fallback: "Server") == "Logs", "Detaching a project also deleted the session name")
        links.prune(available: ["one", "four"])
        precondition(links.sessions(peer: "host|one", workspace: "project") == ["four"])
        precondition(links.title("one", fallback: "Server") == "Logs", "An ended terminal's retained scrollback lost its name")
        links.rename("one", to: " \n ")
        precondition(links.title("one", fallback: "Server") == "Server")

        let remounted = ClientSSHProjectLinks(scope: first, defaults: defaults)
        precondition(remounted.sessions(peer: "host|one", workspace: "project") == ["four"])
        otherAccount.refresh()
        precondition(otherAccount.sessions(peer: "host|one", workspace: "project") == ["foreign"])
        precondition(otherAccount.title("one", fallback: "Server") == "Other account")
        let unknown = ClientSSHProjectLinks(scope: nil, defaults: defaults)
        unknown.attach("unowned", peer: "host", workspace: "project")
        unknown.rename("one", to: "Unowned")
        unknown.prune(available: [])
        precondition(unknown.sessions(peer: "host", workspace: "project").isEmpty)
        precondition(ClientSSHProjectLinks(scope: first, defaults: defaults).sessions(peer: "host|one", workspace: "project") == ["four"])
        var current = true
        let guarded = ClientSSHProjectLinks(scope: first, defaults: defaults, isOwnerCurrent: { current })
        current = false
        guarded.attach("retired", peer: "host|one", workspace: "project")
        guarded.rename("four", to: "stale rename")
        guarded.prune(available: [])
        precondition(guarded.sessions(peer: "host|one", workspace: "project").isEmpty)
        let fresh = ClientSSHProjectLinks(scope: first, defaults: defaults)
        precondition(fresh.sessions(peer: "host|one", workspace: "project") == ["four"])
        precondition(fresh.title("four", fallback: "Server") == "Server")
        print("SSH project links: explicit associations, stable order, remounts, account/host isolation, names and multi-window merges passed")
    }
}
