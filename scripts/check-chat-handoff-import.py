#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production draft import guard while a local file is staging."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
start = source.index('    func importHandoffDraft(')
end = source.index('\n    }', start) + len('\n    }')
method = source[start:end]
harness = '''import Foundation
struct WorkReference: Equatable { let scope: String }
struct ChatAttachment: Equatable { let id: String }
struct WorkSharedDraft: Equatable { let text: String; let attachmentIDs: [String] }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope = "fixture"
}
@MainActor final class ChatDraftStore {
    static let shared = ChatDraftStore()
    var saves = 0
    func save(text: String, attachments: [ChatAttachment], for reference: WorkReference, newMessage: Bool) { saves += 1 }
}
@MainActor final class Model {
    let currentReference = WorkReference(scope: "fixture")
    let draftReference = WorkReference(scope: "fixture")
    var savedCopy: Bool? = nil
    var sending = false
    var stagingAttachments = 0
    var heldSubmission: Bool? = nil
    var unconfirmedSend: Bool? = nil
    var draftSaveTask: Task<Void, Never>?
    var draft = "local draft"
    var attachments = [ChatAttachment(id: "local")]
    var attachmentPreviews: [String: Data] = [:]
    var missingDraftAttachments: [String] = []
    var draftAttachmentLoadGeneration = UUID()
    var handoffDraft: WorkSharedDraft { .init(text: draft, attachmentIDs: attachments.map(\\.id)) }
    func setDraft(_ value: String) { draft = value }
''' + method + '''
}
@main struct Check {
    @MainActor static func main() {
        let model = Model()
        let original = model.handoffDraft
        let shared = WorkSharedDraft(text: "other device", attachmentIDs: ["remote"])
        let files = [ChatAttachment(id: "remote")]
        model.stagingAttachments = 1
        precondition(!model.importHandoffDraft(shared, files: files, replacing: original, reference: model.currentReference), "handoff must wait for the pending local file")
        precondition(model.handoffDraft == original && ChatDraftStore.shared.saves == 0)
        // A completed local import changes the draft; the old confirmation
        // must not silently replace that new attachment either.
        model.attachments.append(.init(id: "newly-staged"))
        model.stagingAttachments = 0
        precondition(!model.importHandoffDraft(shared, files: files, replacing: original, reference: model.currentReference))
        let current = model.handoffDraft
        precondition(model.importHandoffDraft(shared, files: files, replacing: current, reference: model.currentReference))
        precondition(model.handoffDraft == shared && ChatDraftStore.shared.saves == 1)
        print("Handoff import: pending files preserved, stale confirmation refused, completed import saved once")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-handoff-import-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
