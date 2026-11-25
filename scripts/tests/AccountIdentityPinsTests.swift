// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift.
import Foundation

@main struct AccountIdentityPinsTests {
    static func main() {
        let suite = "AccountIdentityPinsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Never activated: the plain rule, and nothing is remembered.
        let plain = AccountIdentityPins()
        assert(plain.identity(handle: "alice", id: "acc_a") == "alice")
        assert(plain.identity(handle: nil, id: "acc_a") == "acc_a")
        assert(plain.accountID(for: "alice") == nil)

        let pins = AccountIdentityPins()
        pins.activate(defaults)
        // Claiming a handle does not move what was filed before it.
        assert(pins.identity(handle: nil, id: "acc_new") == "acc_new")
        assert(pins.identity(handle: "newname", id: "acc_new") == "acc_new")
        // An account already filed under its handle stays there through a
        // change, and through a relaunch.
        assert(pins.identity(handle: "alice", id: "acc_a") == "alice")
        assert(pins.identity(handle: "alicia", id: "acc_a") == "alice")
        let relaunched = AccountIdentityPins()
        relaunched.activate(defaults)
        assert(relaunched.identity(handle: "alicia", id: "acc_a") == "alice")
        assert(relaunched.accountID(for: "alice") == "acc_a")
        assert(relaunched.accountID(for: "acc_new") == "acc_new")
        // Somebody else claims the freed name on this device. They never open
        // what the first person filed under it.
        assert(relaunched.identity(handle: "alice", id: "acc_b") == "acc_b")

        // The scope files under the pin and names the account to a host by id.
        AccountIdentityPins.shared.activate(defaults)
        let identity = WorkReference.Scope.accountIdentity(handle: "alicia", id: "acc_a")!
        let scope = WorkReference.Scope.account(origin: "https://example.com", handle: identity)!
        assert(scope.identity == "alice" && scope.wireIdentity == "acc_a")
        // A server too old to send an id still has an identity.
        assert(WorkReference.Scope.accountIdentity(handle: " bob ", id: nil) == "bob")
        assert(WorkReference.Scope.accountIdentity(handle: "", id: " ") == nil)
        print("Account identity: claims and renames keep local work, reused names never share it")
    }
}
