#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the composer's production steering reservation against host capabilities."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()

def member(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

members = '\n'.join(member(signature) for signature in [
    '    var nativeSteerAcceptsAttachments:', '    var sendsAsNote:',
    '    private var steerBackend:', '    private var steerAutonomy:',
    '    enum BusyNoteStart', '    func beginBusyNote(',
    '    enum SignInHold', '    func holdForSignIn(',
])
stub = '''import Foundation
enum L10n { static func text(_ key: String) -> String { key } }
struct ChatAttachment: Equatable { let id: String }
struct Conversation {
    var id = "chat"
    var nativeSteer: Bool? = true
    var nativeSteerAttachments: Bool? = true
    var backend = "claude"
    var autonomy = "bypass"
    var mode = "execute"
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope? = .local(installationID: "test")
}
@MainActor final class Model {
    var selected: Conversation? = Conversation()
    var busy = true
    var attachments = [ChatAttachment(id: "image")]
    var stagingAttachments = 0
    var savedCopy: Bool? = nil
    var remoteSteer: Bool? = false
    var peer: String? = nil
    var sending = false
    var draft = "Add the highlighted detail"
    var draftMessageID: String? = "message"
    var contextRevision: UInt64? = 3
    var selectionGeneration: UInt64 = 4
    var currentReference: WorkReference? = WorkReference(scope: .local(installationID: "test"),
        hostIdentity: "host", workspaceID: "project", kind: .conversation, itemID: "chat")
    var busyNoteSubmission: ChatDraftSubmission?
    var busyNoteToken: UInt64?
    var signInQueuedMessage: Bool? = nil
    var backendRefreshError: String? = nil
    func needsSignIn(_ backend: String) -> Bool { true }
    func enqueue(_ text: String, awaitingSignIn: Bool) -> Bool? { signInQueuedMessage = true; return true }
    func clearDraft() { draft = "" }
    func saveDraftNow() {}
    func noteSendStarted() -> UInt64 { sending = true; return 1 }
'''
tests = '''
}
@main enum Tests {
    @MainActor static func main() {
        let model = Model()
        assert(model.sendsAsNote)
        guard case .notNeeded = model.holdForSignIn(model.draft, backend: "claude") else { fatalError("Stale sign-in status must not block an already active native CLI") }
        guard case .steering = model.beginBusyNote(model.draft) else { fatalError("An image on a capable live host must steer") }
        assert(model.busyNoteSubmission?.attachments == model.attachments, "The reserved send must retain every attachment")
        assert(model.busyNoteSubmission?.expectedRevision == 3 && model.busyNoteSubmission?.generation == 4)
        model.attachments = []
        model.draft = "A later draft"
        assert(model.busyNoteSubmission?.attachments == [ChatAttachment(id: "image")], "Later edits cannot change the reserved payload")
        let oldHost = Model()
        oldHost.selected?.nativeSteerAttachments = nil
        assert(!oldHost.sendsAsNote)
        guard case .queue = oldHost.beginBusyNote(oldHost.draft) else { fatalError("Older hosts must keep image messages queued") }
        assert(oldHost.busyNoteSubmission == nil && !oldHost.sending && oldHost.attachments.count == 1)
        oldHost.attachments = []
        assert(oldHost.sendsAsNote, "Text steering remains available on older native hosts")
        let stale = Model()
        stale.selected?.nativeSteer = false
        assert(!stale.sendsAsNote)
        guard case .queue = stale.beginBusyNote(stale.draft) else { fatalError("An attachment capability alone cannot send files to the legacy text hook") }
        let uploading = Model()
        uploading.stagingAttachments = 1
        assert(!uploading.sendsAsNote)
        guard case .queue = uploading.beginBusyNote(uploading.draft) else { fatalError("Unfinished uploads cannot be steered") }
        let imageOnly = Model()
        guard case .steering = imageOnly.beginBusyNote("") else { fatalError("Image-only steering must retain the attachment") }
        print("Steering submission: image reservation, changed draft, older/stale hosts and unfinished uploads passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-steer-submission-') as work:
    work = Path(work)
    swift = work / 'Tests.swift'
    swift.write_text(stub + members + tests)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
        '-module-cache-path', str(work / 'cache'), '-o', str(work / 'test'), str(swift),
        str(root / 'apps/mac/Sources/Features/Work/WorkReference.swift'),
        str(root / 'apps/mac/Sources/Features/Work/ChatDraftSubmission.swift')], check=True)
    subprocess.run([str(work / 'test')], check=True)
