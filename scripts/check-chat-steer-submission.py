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
    '    func finishBusyNote(', '    func consumeChatCommand(',
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
enum RemoteHostFeature { case steer; var minimumProtocol: Int { 1 } }
@MainActor enum Bridge {
    static var steerCalls = 0
    static func peerProtocolVersion(_ peer: String) async throws -> Int { 99 }
    static func steerChat(id: String, text: String, peer: String?) async throws { steerCalls += 1 }
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
    var error: String? = nil
    var showingCommandStats = false
    var chatCommandSelection = 0
    var stopped: [String] = []
    var queuedSubmission: ChatDraftSubmission?
    var queuedAsSteer: Bool?
    func needsSignIn(_ backend: String) -> Bool { true }
    func enqueue(_ text: String, awaitingSignIn: Bool) -> Bool? { signInQueuedMessage = true; return true }
    func clearDraft() { draft = "" }
    func saveDraftNow() {}
    func noteSendStarted() -> UInt64 { sending = true; return 1 }
    func noteSendFinished(_ token: UInt64) { sending = false }
    func queueBusyNote(_ submission: ChatDraftSubmission, deliverAsSteer: Bool = false) {
        queuedSubmission = submission; queuedAsSteer = deliverAsSteer
    }
    func rememberSteerMutation(_ reference: WorkReference, note: String?) {}
    func parkLocalSteer(_ text: String) {}
    func isUnknownMethod(_ error: Error) -> Bool { false }
    func hostMessage(_ error: Error) -> String { error.localizedDescription }
    static func steerFallsBack(_ message: String) -> Bool { false }
    func stop() async { if let selected { stopped.append(selected.id) } }
'''
tests = '''
}
@main enum Tests {
    @MainActor static func main() async {
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
        for draft in ["/usr/local/file", String(repeating: "a", count: 1_501), String(repeating: "👩‍💻", count: 501)] {
            let literal = Model()
            literal.draft = draft
            assert(!literal.sendsAsNote, "The composer must not offer unsupported steering payloads")
            guard case .queue = literal.beginBusyNote(draft) else { fatalError("Literal paths and long prompts must wait for a normal turn") }
            assert(literal.busyNoteSubmission == nil && !literal.sending)
        }
        for nativeStillPresent in [false, true] {
            let retired = Model()
            guard case let .steering(token) = retired.beginBusyNote(retired.draft) else { fatalError() }
            retired.selected?.nativeSteer = nativeStillPresent
            retired.selected?.nativeSteerAttachments = false
            retired.selected?.autonomy = "standard"
            retired.remoteSteer = true
            await retired.finishBusyNote(token)
            assert(retired.queuedSubmission?.attachments == retired.attachments && retired.queuedAsSteer == false,
                   "A retiring native capability must queue the complete attached payload")
            assert(Bridge.steerCalls == 0, "The legacy text hook cannot receive a reserved attached message")
        }
        let command = Model()
        command.attachments = []
        command.draft = "/stop"
        assert(command.consumeChatCommand())
        command.selected?.id = "other-chat"
        command.selectionGeneration += 1
        for _ in 0..<20 { await Task.yield() }
        assert(command.stopped.isEmpty, "A deferred stop command cannot target a newly selected conversation")
        let unchanged = Model()
        unchanged.attachments = []
        unchanged.draft = "/stop"
        assert(unchanged.consumeChatCommand())
        for _ in 0..<100 where unchanged.stopped.isEmpty { await Task.yield() }
        assert(unchanged.stopped == ["chat"], "An unchanged stop command still stops its captured chat")
        let saved = Model()
        saved.savedCopy = true
        saved.attachments = []
        saved.draft = "/stop"
        assert(saved.consumeChatCommand() && saved.draft == "/stop" && saved.stopped.isEmpty)
        print("Steering submission: payload limits, attachment capability changes, reservation and stop-command ownership passed")
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
        str(root / 'apps/mac/Sources/Features/Work/ChatDraftSubmission.swift'),
        str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatSteerContext.swift'),
        str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatCommandRules.swift')], check=True)
    subprocess.run([str(work / 'test')], check=True)
