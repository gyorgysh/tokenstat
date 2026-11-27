// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct ChatLocalSharingInfo: Decodable, Sendable {
    struct Sharing: Decodable, Sendable {
        let id: String
        let revision: UInt64
        let phase: String
        let privateReady: Bool
        let sourceOnly: Bool?
        let accountCleanupPending: Bool
        let agentRunHeld: Bool?
    }
    let sharing: Sharing?
}

struct ChatLocalSharingStopped: Decodable, Sendable {
    let stoppedLocally: Bool
    let privateReady: Bool
    let localRecoveryNeeded: Bool
    let accountCleanupPending: Bool
}

struct ChatAgentRunRecovered: Decodable, Sendable {
    let recovered: Bool
}

#if os(macOS)
extension Bridge {
    static func localChatSharing(workspaceID: String, id: String,
                                 scope: WorkReference.Scope, generation: UInt64) async throws -> ChatLocalSharingInfo {
        try await chatInvoke(peer: nil, "chat.sharing.info", ["workspaceId": workspaceID, "id": id],
                             expectedScope: scope, expectedGeneration: generation, as: ChatLocalSharingInfo.self)
    }

    static func stopLocalChatSharing(workspaceID: String, id: String, sharing: ChatLocalSharingInfo.Sharing,
                                     scope: WorkReference.Scope, generation: UInt64) async throws -> ChatLocalSharingStopped {
        try await chatInvoke(peer: nil, "chat.sharing.stopLocal", ["workspaceId": workspaceID, "id": id,
            "share": sharing.id, "expectedRevision": sharing.revision, "sourceOnly": sharing.sourceOnly == true, "confirmStop": true],
            expectedScope: scope, expectedGeneration: generation, as: ChatLocalSharingStopped.self)
    }

    static func recoverAgentRun(workspaceID: String, id: String,
                                scope: WorkReference.Scope, generation: UInt64) async throws -> ChatAgentRunRecovered {
        try await chatInvoke(peer: nil, "chat.sharing.recoverRun", ["workspaceId": workspaceID, "id": id, "confirmRecovery": true],
                             expectedScope: scope, expectedGeneration: generation, as: ChatAgentRunRecovered.self)
    }
}
#endif
