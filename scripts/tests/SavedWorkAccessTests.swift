// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift SavedWorkAccess.swift.
import Foundation

@main struct SavedWorkAccessTests {
    @MainActor static func main() {
        let suite = "SavedWorkAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let alice = SavedWorkOwner(scope: .account(origin: "https://example.com", handle: "alice")!,
                                  name: "Alice", hosts: ["host-a": "Studio"])
        let bob = SavedWorkOwner(scope: .account(origin: "https://example.com", handle: "bob")!,
                                name: "Bob", hosts: ["host-b": "Laptop"])
        let first = SavedWorkAccess(defaults: defaults)
        assert(first.offeredOwner == nil && !first.beginReading(alice))
        first.verified(alice)
        assert(first.offeredOwner == nil && first.reader == nil)
        // A cold start remembers ownership, never an authenticated account.
        let cold = SavedWorkAccess(defaults: defaults)
        assert(cold.offeredOwner == alice && cold.reader == nil)
        assert(!cold.beginReading(bob))
        assert(cold.beginReading(alice))
        let opened = cold.generation
        assert(cold.reader == alice)
        cold.endReading()
        assert(cold.reader == nil && cold.generation != opened)
        assert(cold.beginReading(alice))
        // Account verification closes reading, even if it is the same account.
        cold.verified(alice)
        assert(cold.reader == nil && cold.offeredOwner == nil)
        cold.verified(bob)
        let changed = SavedWorkAccess(defaults: defaults)
        assert(changed.offeredOwner == bob && !changed.beginReading(alice))
        assert(changed.beginReading(bob))
        // Definitive sign-out revokes the offer, including after relaunch.
        changed.verified(nil)
        assert(changed.reader == nil && !changed.beginReading(bob))
        assert(SavedWorkAccess(defaults: defaults).offeredOwner == nil)
        // An unknown state cannot resurrect a removed owner.
        changed.accountUnknown()
        assert(changed.offeredOwner == nil)
        first.verified(SavedWorkOwner(scope: .local(installationID: "local"), name: "Local", hosts: [:]))
        assert(SavedWorkAccess(defaults: defaults).offeredOwner == nil)
        defaults.set(Data("corrupt".utf8), forKey: "work.savedOwner.v1")
        assert(SavedWorkAccess(defaults: defaults).offeredOwner == nil)
        defaults.set(Data(repeating: 0, count: 129 * 1024), forKey: "work.savedOwner.v1")
        assert(SavedWorkAccess(defaults: defaults).offeredOwner == nil)
        print("Saved work access: explicit opening, cold ownership, account replacement, revocation and corruption passed")
    }
}
