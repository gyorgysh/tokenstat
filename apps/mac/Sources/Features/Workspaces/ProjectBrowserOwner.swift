// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@MainActor
enum ProjectBrowserOwner {
    static func make(workspaceID: String, peer: String? = nil) -> ProjectBrowserSession {
        let owner = WorkViewedChange.owner(folderID: workspaceID, peer: peer)
        return ProjectBrowserSession(owner: owner, peer: peer, isCurrent: {
            WorkSessionContext.shared.scope == owner?.scope
                && (peer != nil || WorkSessionContext.shared.localHostIdentity == owner?.hostIdentity)
        })
    }
}
