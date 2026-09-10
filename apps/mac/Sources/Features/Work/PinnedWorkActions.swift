// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Home shortcuts are independent of saved-copy retention. Only the explicit
/// Keep offline control changes whether a copy survives automatic expiry.
@MainActor
enum PinnedWorkActions {
    @discardableResult
    static func pin(_ reference: WorkReference, label: String, folderName: String) async -> Bool {
        guard PinnedWorkStore.shared.pin(reference, label: label, folderName: folderName) else { return false }
        return true
    }

    static func unpin(_ reference: WorkReference) async {
        PinnedWorkStore.shared.unpin(reference)
    }
}

extension Account {
    /// The scope pins file under. Same account the recent places use, so a
    /// pin and the history row it came from never disagree about whose they
    /// are.
    var pinnedWorkScope: WorkReference.Scope? {
        guard signedIn else { return nil }
        return PinnedWorkStore.scope(host: host, handle: handle)
    }
}
