// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Live transport captured when a conversation opens its handoff sheet.
/// Every suspension rechecks the account, linked host and exact selection.
@MainActor
final class WorkHandoffConnection {
    struct Unavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let reference: WorkReference
    private let conversationID: String
    private weak var chat: ChatModel?
    private let selectionGeneration: UInt64
    private let peer: String?
    private let hostIsLinked: @MainActor () -> Bool

    init?(chat: ChatModel, hostIsLinked: @escaping @MainActor () -> Bool) {
        guard let reference = chat.currentReference, let conversationID = reference.itemID,
              reference.scope == WorkSessionContext.shared.scope,
              chat.savedCopy == nil else { return nil }
        self.reference = reference
        self.conversationID = conversationID
        self.chat = chat
        selectionGeneration = chat.selectionGeneration
        peer = chat.peer
        self.hostIsLinked = hostIsLinked
    }

    var isCurrent: Bool {
        guard let chat, !Task.isCancelled,
              reference.scope == WorkSessionContext.shared.scope,
              chat.currentReference == reference, chat.peer == peer,
              chat.selectionGeneration == selectionGeneration,
              chat.savedCopy == nil else { return false }
        return peer == nil || hostIsLinked()
    }

    private func requireCurrent() throws {
        guard isCurrent else {
            throw Unavailable(message: "Open this conversation again to continue sharing.")
        }
    }

    private func prepare() async throws {
        try requireCurrent()
        guard let peer else { return }
        let allowed = try await Bridge.workspaceAccessAllowed(peer: peer)
        try requireCurrent()
        guard allowed else {
            throw Unavailable(message: "Allow workspace access on the other computer to share this work.")
        }
        let version = try await Bridge.peerProtocolVersion(peer)
        try requireCurrent()
        guard version >= RemoteHostFeature.handoff.minimumProtocol else {
            throw Unavailable(message: "Update tokenstat on the other computer to continue work between devices.")
        }
    }

    func makeModel() -> WorkHandoffModel {
        WorkHandoffModel(reference: reference, ownsDestination: { [self] in isCurrent },
            fetch: { [self] in
                try await prepare()
                let result = try await Bridge.workHandoff(workspaceID: reference.workspaceID,
                    conversationID: conversationID, peer: peer)
                try requireCurrent()
                return result
            }, put: { [self] request in
                try await prepare()
                let result = try await Bridge.putWorkHandoff(workspaceID: reference.workspaceID,
                    conversationID: conversationID, request: request, peer: peer)
                try requireCurrent()
                return result
            })
    }

    func attachments(for draft: WorkSharedDraft) async throws -> [ChatAttachment] {
        try await prepare()
        // Even an empty list verifies that the exact conversation still exists
        // under the host's ownership/deletion lock, without fetching file bytes.
        let result = try await Bridge.workHandoffAttachments(workspaceID: reference.workspaceID,
            conversationID: conversationID, attachmentIDs: draft.attachmentIDs, peer: peer)
        try requireCurrent()
        guard result.map(\.id) == draft.attachmentIDs else {
            throw Unavailable(message: "Some shared files are no longer available. Your draft has not changed.")
        }
        return result
    }

    /// Permission may change while the preview is open, including when the
    /// shared work has no files whose metadata would otherwise be requested.
    func verifyForImport() async throws {
        _ = try await attachments(for: WorkSharedDraft(text: "", attachmentIDs: []))
    }
}
