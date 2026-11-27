// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

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
    var pinnedWorkScope: WorkReference.Scope? {
        guard signedIn else { return nil }
        return PinnedWorkStore.scope(host: host, handle: handle, id: accountId)
    }
}
