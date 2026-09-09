// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Pure identifier routing shared by chat loads and sidebar actions. Resolving
/// a local destination deliberately produces nil; nil is not a missing route.
enum WorkDestinationResolver {
    /// Anchors choose a reading position, not a different conversation.
    /// Missing or malformed references never match, including nil with nil.
    static func sameConversation(_ a: WorkReference?, _ b: WorkReference?) -> Bool {
        guard let a, let b, let key = WorkReferenceKey.conversation(a) else { return false }
        return key == WorkReferenceKey.conversation(b)
    }

    /// Only the named folder in the still-active account may consume a request.
    static func requestedConversation(_ request: WorkReference?, scope: WorkReference.Scope?,
                                      peer: String, workspaceID: String) -> String? {
        guard let request, request.scope == scope, request.hostIdentity == peer,
              request.workspaceID == workspaceID,
              WorkReferenceKey.conversation(request) != nil else { return nil }
        return request.itemID
    }

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
