// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@MainActor enum WorkCacheAccess {
    static func canRead(_ reference: WorkReference) -> Bool {
        reference.scope == WorkSessionContext.shared.readingScope
            && WorkAccessStore.shared.allowed(scope: reference.scope, host: reference.hostIdentity) != false
    }

    static func canSave(_ reference: WorkReference) -> Bool {
        reference.scope == WorkSessionContext.shared.scope && canRead(reference)
    }

    /// A learned revocation removes the host's copies, including previews.
    /// Deletion failures do not grant reading permission: canRead remains false.
    static func purge(host: String, scope: WorkReference.Scope) async {
        let wireScope = WorkCache.scope(for: scope)
        guard let listing = try? await Bridge.cacheList(scope: wireScope) else { return }
        for record in listing.records where record.scope == wireScope {
            let reference = WorkCache.reference(recordID: record.id, scope: scope)
                ?? WorkSavedPreview.reference(recordID: record.id, scope: scope)
            guard reference?.hostIdentity == host || record.kind == "searchHistory" else { continue }
            _ = try? await Bridge.cacheRemove(scope: wireScope, id: record.id)
        }
    }
}
