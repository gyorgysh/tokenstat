// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkHandoffConnection.swift, WorkHandoffModel.swift, WorkHandoff.swift and WorkReference.swift.
import Foundation

@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
}
@MainActor final class ChatModel {
    var currentReference: WorkReference?
    var selectionGeneration: UInt64 = 1
    var peer: String? = "host"
    var savedCopy: Bool?
}
enum RemoteHostFeature {
    case handoff
    var minimumProtocol: Int { 12 }
}
struct ChatAttachment { let id: String }
@MainActor enum Bridge {
    static var calls: [String] = []
    static var allowed = true
    static var version = 12
    static var afterAccess: (() -> Void)?
    static var returnedIDs: [String] = []
    static var missingConversation = false
    enum Failure: Error { case deleted }
    static func workspaceAccessAllowed(peer: String) async throws -> Bool {
        calls.append("access")
        afterAccess?()
        return allowed
    }
    static func peerProtocolVersion(_ peer: String) async throws -> Int {
        calls.append("protocol")
        return version
    }
    static func workHandoff(workspaceID: String, conversationID: String, peer: String?) async throws -> WorkHandoff? {
        calls.append("read:\(workspaceID):\(conversationID)")
        return nil
    }
    static func putWorkHandoff(workspaceID: String, conversationID: String,
                               request: WorkHandoffRequest, peer: String?) async throws -> WorkHandoffResult {
        calls.append("write")
        return .conflict(nil)
    }
    static func workHandoffAttachments(workspaceID: String, conversationID: String,
                                       attachmentIDs: [String], peer: String?) async throws -> [ChatAttachment] {
        calls.append("attachments")
        if missingConversation { throw Failure.deleted }
        return returnedIDs.map { ChatAttachment(id: $0) }
    }
}

@main struct WorkHandoffConnectionTests {
    @MainActor static func main() async {
        let scope = WorkReference.Scope.account(origin: "https://example.invalid", handle: "test")!
        WorkSessionContext.shared.scope = scope
        let chat = ChatModel()
        chat.currentReference = WorkReference(scope: scope, hostIdentity: "host",
            workspaceID: "folder", kind: .conversation, itemID: "chat")
        var linked = true
        let connection = WorkHandoffConnection(chat: chat, hostIsLinked: { linked })!
        let model = connection.makeModel()
        Bridge.version = 11
        await model.load()
        assert(model.phase == .failed && Bridge.calls == ["access", "protocol"])
        Bridge.calls = []
        Bridge.version = 12
        Bridge.allowed = false
        await model.load()
        assert(Bridge.calls == ["access"])
        Bridge.calls = []
        Bridge.allowed = true
        await model.load()
        assert(model.phase == .ready && Bridge.calls == ["access", "protocol", "read:folder:chat"])

        Bridge.calls = []
        Bridge.afterAccess = { linked = false }
        await model.share(deviceName: "Phone", draft: nil, anchor: nil)
        assert(Bridge.calls == ["access"] && model.phase == .invalidated)
        Bridge.afterAccess = nil
        linked = true
        let draft = WorkSharedDraft(text: "draft", attachmentIDs: ["one", "two"])
        Bridge.returnedIDs = ["two", "one"]
        do {
            _ = try await connection.attachments(for: draft)
            assertionFailure("Mismatched attachment descriptors must be rejected")
        } catch {}
        Bridge.returnedIDs = draft.attachmentIDs
        let files = try! await connection.attachments(for: draft)
        assert(files.map(\.id) == draft.attachmentIDs)

        // Text-only drafts and reading positions still need current access.
        Bridge.calls = []
        Bridge.allowed = false
        do {
            _ = try await connection.attachments(for: WorkSharedDraft(text: "text only", attachmentIDs: []))
            assertionFailure("Revoked access must block text-only import too")
        } catch {}
        do {
            try await connection.verifyForImport()
            assertionFailure("Revoked access must block reading-position import")
        } catch {}
        assert(Bridge.calls == ["access", "access"])
        Bridge.allowed = true

        Bridge.calls = []
        Bridge.returnedIDs = []
        Bridge.missingConversation = true
        do {
            try await connection.verifyForImport()
            assertionFailure("A deleted conversation must not receive a reading position")
        } catch {}
        assert(Bridge.calls == ["access", "protocol", "attachments"])
        Bridge.missingConversation = false

        Bridge.calls = []
        chat.selectionGeneration += 1 // Same identifiers reopened are a new selection.
        assert(!connection.isCurrent)
        do {
            _ = try await connection.attachments(for: draft)
            assertionFailure("An old sheet must not fetch files")
        } catch {}
        assert(Bridge.calls.isEmpty)
        chat.savedCopy = true
        assert(WorkHandoffConnection(chat: chat, hostIsLinked: { true }) == nil)
        print("Handoff connection: protocol/access gates, removed host, exact selection and attachment identity passed")
    }
}
