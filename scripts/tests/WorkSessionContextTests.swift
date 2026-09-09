// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift SavedWorkAccess.swift WorkSessionContext.swift.
import Foundation

struct Machine { var publicIdentity: String?; var displayName: String }
struct Account {
    var signedIn: Bool
    var host: String
    var handle: String?
    var title: String?
    var machines: [Machine]
}
enum Bridge {
    struct Identity { let key: String }
    static func machineIdentity() async throws -> Identity { Identity(key: "local-host") }
}

@main struct WorkSessionContextTests {
    @MainActor static func main() async {
        let suite = "WorkSessionContextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = WorkReference.Scope.account(origin: "https://example.com", handle: "alice")!
        let firstAccess = SavedWorkAccess(defaults: defaults)
        let firstContext = WorkSessionContext(defaults: defaults, savedAccess: firstAccess)
        firstContext.update(account: Account(signedIn: true, host: scope.origin, handle: "alice", title: "Alice",
            machines: [Machine(publicIdentity: "host-a", displayName: "Studio")]))
        assert(firstContext.scope == scope && firstContext.readingScope == scope)
        // Relaunch while the account cannot answer. The saved owner never
        // grants a live scope; only an explicit reader gets a reading scope.
        let coldAccess = SavedWorkAccess(defaults: defaults)
        let coldContext = WorkSessionContext(defaults: defaults, savedAccess: coldAccess)
        assert(coldContext.scope == nil && coldContext.readingScope == nil)
        let owner = coldAccess.offeredOwner!
        assert(coldAccess.beginReading(owner))
        assert(coldContext.scope == nil && coldContext.readingScope == scope)
        coldAccess.endReading()
        assert(coldContext.readingScope == nil)
        assert(coldAccess.beginReading(owner))
        coldContext.update(account: Account(signedIn: true, host: scope.origin, handle: "bob", title: "Bob", machines: []))
        assert(coldAccess.reader == nil && coldContext.scope?.identity == "bob")
        assert(coldContext.readingScope == coldContext.scope)
        assert(!coldAccess.beginReading(owner))
        // A definitive sign-out neither keeps account read access nor offers
        // that account after the next offline launch.
        coldContext.update(account: Account(signedIn: false, host: scope.origin, handle: nil, title: nil, machines: []))
        assert(coldContext.scope?.kind == .local && coldAccess.reader == nil)
        assert(SavedWorkAccess(defaults: defaults).offeredOwner == nil)
        await coldContext.resolveLocalHostIdentity()
        assert(coldContext.localHostIdentity == "local-host")
        print("Work session context: saved reading never authenticates, account switching and sign-out revoke access")
    }
}
