// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Pure identifier routing shared by chat loads and sidebar actions. Resolving
/// a local destination deliberately produces nil; nil is not a missing route.
enum WorkDestinationResolver {
    struct Route: Equatable, Sendable {
        let workspaceID: String
        let peer: String?
    }

    static func route(folderID: String, explicitPeer: String? = nil) -> Route {
        let parts = folderID.split(separator: ":", maxSplits: 2).map(String.init)
        let remote = folderID.hasPrefix("remote:") && parts.count == 3
        let workspace = remote ? parts[2] : folderID
        if let explicitPeer, !explicitPeer.isEmpty {
            return Route(workspaceID: workspace, peer: explicitPeer)
        }
        return Route(workspaceID: workspace, peer: remote ? parts[1] : nil)
    }

    static func deletionPeer(folderID: String?, currentFolderID: String? = nil, currentPeer: String?) -> String? {
        guard let folderID else { return currentPeer }
        // Mobile models carry a raw folder id and an explicit peer; only the
        // current folder may inherit that peer. Other sidebar folders resolve
        // independently, including an intentional nil for local work.
        return route(folderID: folderID,
                     explicitPeer: folderID == currentFolderID ? currentPeer : nil).peer
    }

    static func route(reference: WorkReference, currentScope: WorkReference.Scope,
                      localHostIdentity: String) -> Route? {
        guard reference.scope == currentScope, !reference.hostIdentity.isEmpty,
              !reference.workspaceID.isEmpty else { return nil }
        return Route(workspaceID: reference.workspaceID,
                     peer: reference.hostIdentity == localHostIdentity ? nil : reference.hostIdentity)
    }
}
