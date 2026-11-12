#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production composer and receipt cleanup around a rotated delivery."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()

def member(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('ChatOutboxStore.shared', 'outbox').replace('private func ', 'func ', 1)

methods = '\n'.join(member(name) for name in [
    '    func holdDraftForSending(', '    func sendFromComposer(', '    private func clearSubmittedDraft(',
    '    private func queuedDeliveries(', '    private func deliveryID('
])
fixture = r'''
import Foundation
struct ChatAttachment: Codable, Equatable, Sendable { let id: String; let name: String }
struct Conversation { let id: String }
struct Draft: Equatable { let messageID: String?; let text: String; let attachments: [ChatAttachment] }
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope? = .local(installationID: "fixture")
}
@MainActor final class ChatDraftStore {
    static let shared = ChatDraftStore()
    var record: Draft?
    func draft(for reference: WorkReference) -> Draft? { record }
    func save(text: String, attachments: [ChatAttachment], for reference: WorkReference, newMessage: Bool = false) {
        record = Draft(messageID: newMessage ? "new-draft" : record?.messageID, text: text, attachments: attachments)
    }
    func clear(_ expected: Draft) { if record == expected { record = nil } }
}
@MainActor final class Model {
    struct Unconfirmed { let conversationID: String; let messageID: String; var checking: Bool }
    let outbox: ChatOutboxStore
    let reference: WorkReference
    var isSharedSource = false, selectedBackendMissing = false, sending = false
    var savedCopy: String? = nil
    var selected: Conversation? = Conversation(id: "chat")
    var stagingAttachments = 0
    var heldSubmission: ChatDraftSubmission?
    var queued: [ChatQueuedMessage] = []
    var unconfirmedSend: Unconfirmed?
    var error: String?
    var draft = "Original writing"
    var attachments: [ChatAttachment] = []
    var attachmentPreviews: [String: Data] = [:]
    var draftReference: WorkReference? { reference }
    var currentReference: WorkReference? { reference }
    var draftMessageID: String? { ChatDraftStore.shared.record?.messageID }
    var continuityScope: WorkReference.Scope? { reference.scope }
    var peer: String? = nil
    var selectionGeneration: UInt64 = 1
    var contextRevision: UInt64? = 7
    var composerSendToken: UInt64?
    var deliveringFromComposer: String?
    init(directory: URL) {
        reference = WorkReference(scope: .local(installationID: "fixture"), hostIdentity: "host",
                                  workspaceID: "workspace", kind: .conversation, itemID: "chat")
        outbox = ChatOutboxStore(directory: directory)
    }
    func saveDraftNow() {}
    func setDraft(_ value: String) { draft = value }
    func noteSendStarted() -> UInt64 { 1 }
    func noteSendFinished(_ token: UInt64) {}
    func restoreSubmission(_ submission: ChatDraftSubmission) { if draft.isEmpty { draft = submission.draftText } }
    func deliverQueued(_ item: ChatQueuedMessage, stopCurrent: Bool, reserved: Bool) async -> Bool {
        queued = try! outbox.update(reference) { rows in
            let index = rows.firstIndex(where: { $0.id == item.id })!
            rows[index].sourceDraftMessageID = rows[index].sourceDraftMessageID ?? item.id
            rows[index].id = "rotated-" + UUID().uuidString
            rows[index].delivery = .deliveryUnknown
        }
        return false
    }
METHODS
}
@main enum Tests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = Model(directory: directory)
        ChatDraftStore.shared.record = Draft(messageID: "original-draft", text: "Original writing", attachments: [])
        var existing = ChatQueuedMessage(id: "original-draft", text: "Original writing", attachments: [])
        existing.attemptedAt = Date(timeIntervalSince1970: 42)
        existing.sourceDraftText = "Original writing"
        existing.expectedRevision = 7
        model.queued = try model.outbox.update(model.reference) { $0 = [existing] }
        assert(model.holdDraftForSending("Original writing"))
        await model.sendFromComposer()
        let rotated = try model.outbox.items(for: model.reference)[0]
        assert(rotated.sourceDraftMessageID == "original-draft")
        assert(model.draft == "Original writing" && model.unconfirmedSend?.messageID == rotated.id,
               "The composer must check the actual delivery identity after a lost reply")
        assert(!model.holdDraftForSending("Original writing"), "A related uncertain send must block another send")
        let pending = try model.outbox.items(for: model.reference)[0]
        model.clearSubmittedDraft(pending, reference: model.reference)
        assert(ChatDraftStore.shared.record == nil && model.draft.isEmpty && model.unconfirmedSend == nil,
               "A confirmed receipt clears the original composer draft")
        ChatDraftStore.shared.record = Draft(messageID: "another-draft", text: "New writing", attachments: [])
        model.draft = "New writing"
        model.clearSubmittedDraft(pending, reference: model.reference)
        assert(ChatDraftStore.shared.record?.text == "New writing" && model.draft == "New writing",
               "A late receipt must not erase a newer draft")

        let retryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: retryDirectory) }
        let retry = Model(directory: retryDirectory)
        ChatDraftStore.shared.record = Draft(messageID: "original-draft", text: "Original writing", attachments: [])
        var waiting = ChatQueuedMessage(id: "rotated-existing", text: "Original writing", attachments: [])
        waiting.sourceDraftMessageID = "original-draft"
        waiting.attemptedAt = Date(timeIntervalSince1970: 42)
        waiting.sourceDraftText = "Original writing"
        waiting.expectedRevision = 7
        retry.queued = try retry.outbox.update(retry.reference) { $0 = [waiting] }
        assert(retry.holdDraftForSending("Original writing"))
        assert(retry.heldSubmission?.messageID == "rotated-existing",
               "A retry must reuse the delivery that already holds this writing")
        await retry.sendFromComposer()
        let retryRows = try retry.outbox.items(for: retry.reference)
        assert(retryRows.count == 1, "A retry of the same writing must not queue a second message")
        assert(retryRows[0].sourceDraftMessageID == "original-draft")
        print("Rotated uncertain delivery blocks its original draft, clears only that draft after confirmation, "
              + "and a retry reuses the rotated delivery instead of queueing twice")
    }
}
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='tokenstat-rotated-draft-') as directory:
    work = Path(directory)
    (work / 'Tests.swift').write_text(fixture)
    sources = root / 'apps/mac/Sources'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-o', str(work / 'test'),
                    str(work / 'Tests.swift'), str(sources / 'Features/Work/WorkReference.swift'),
                    str(sources / 'Features/Work/ChatOutboxStore.swift'),
                    str(sources / 'Features/Work/ChatDraftSubmission.swift'),
                    str(sources / 'Features/Work/OriginalFileCoordination.swift')], check=True)
    subprocess.run([str(work / 'test')], check=True)
