// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkAccessStore.swift WorkReference.swift.
import Foundation
@main struct WorkAccessStoreTests {
    @MainActor static func main() {
        let suite = "WorkAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = WorkReference.Scope.local(installationID: "a")
        let b = WorkReference.Scope.local(installationID: "b")
        let store = WorkAccessStore(defaults: defaults)
        assert(store.allowed(scope: a, host: "host") == nil)
        store.record(true, scope: a, host: "host")
        assert(store.allowed(scope: a, host: "host") == true)
        assert(store.allowed(scope: b, host: "host") == nil)
        let generation = store.generation
        store.record(true, scope: a, host: "host")
        assert(store.generation == generation)
        store.record(false, scope: a, host: "host")
        let cold = WorkAccessStore(defaults: defaults)
        assert(cold.allowed(scope: a, host: "host") == false)
        cold.clear(scope: a)
        assert(cold.allowed(scope: a, host: "host") == nil)
        print("Work access: unknown, scoped grants, durable refusal, stable updates and clear passed")
    }
}
