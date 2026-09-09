// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Pin and unpin, with the sealed copy following the pin.
///
/// A pinned conversation's copy survives age eviction inside the hard budget;
/// unpinning hands it back to the ordinary quota. Either way the pin itself
/// is only ever identifiers and a label. Folder pins carry no copy and answer
/// nothing on the cache side.
@MainActor
enum PinnedWorkActions {
    @discardableResult
    static func pin(_ reference: WorkReference, label: String, folderName: String) async -> Bool {
        guard PinnedWorkStore.shared.pin(reference, label: label, folderName: folderName) else { return false }
        await WorkCacheStore.shared.setPinned(true, for: reference)
        return true
    }

    static func unpin(_ reference: WorkReference) async {
        PinnedWorkStore.shared.unpin(reference)
        await WorkCacheStore.shared.setPinned(false, for: reference)
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
