#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the composer's production steering reservation against host capabilities."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()

def member(signature, source=source):
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
    '    static func newChatDefaults(', '    static var newChatInitialAutonomy:', '    private struct LaunchChoice:',
    '    enum SignInHold', '    func holdForSignIn(',
    '    func finishBusyNote(', '    func consumeChatCommand(', '    func sendInitialDraft(',
])
members = members.replace('UserDefaults.standard', 'FixtureDefaults.standard')
activity = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatActivityView.swift').read_text()
activity_section = member('enum ChatActivitySection:', activity)
stub = '''import Foundation
enum L10n { static func text(_ key: String) -> String { key } }
struct ChatAttachment: Equatable { let id: String }
struct ChatBackend {
    var id: String
    var installed: Bool? = true
    var models: [String] = ["model"]
    var efforts: [String] = ["high"]
    var gateTier: String? = nil
}
@MainActor final class FixtureDefaults {
    static let standard = FixtureDefaults()
    var saved: Data?
    func data(forKey: String) -> Data? { saved }
}
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
    private static let launchChoiceKey = "fixture"
    var selected: Conversation? = Conversation()
    var busy = true
    var attachments = [ChatAttachment(id: "image")]
    var stagingAttachments = 0
    var savedCopy: Bool? = nil
    var isSharedSource = false
    var restoredDraft: String?
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
    var showingActivity = false
    var activitySection: ChatActivitySection?
    var chatCommandSelection = 0
    var stopped: [String] = []
    var queuedSubmission: ChatDraftSubmission?
    var queuedAsSteer: Bool?
    var needsAuthentication = true
    var initialSends = 0
    var reservedInitialText: String?
    func needsSignIn(_ backend: String) -> Bool { needsAuthentication }
    func holdDraftForSending(_ text: String) -> Bool { reservedInitialText = text; return true }
    func sendFromComposer() async { initialSends += 1 }
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
    func restoreSubmission(_ submission: ChatDraftSubmission) { restoredDraft = submission.draftText }
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
        for running in [false, true] {
            for savedCopy in [false, true] {
                for name in ["/goal", "/plan", "/subagents", "/status", "/context", "/usage", "/mcp", "/tools", "/help"] {
                    let readonly = Model()
                    readonly.attachments = []
                    readonly.busy = running
                    readonly.savedCopy = savedCopy ? true : nil
                    readonly.draft = name
                    assert(readonly.consumeChatCommand() && readonly.draft.isEmpty)
                    let section = ChatActivitySection(command: name)
                    assert(readonly.showingActivity == (section != nil)
                           && readonly.activitySection == section
                           && readonly.showingCommandStats == (section == nil),
                           "Read-only commands must open their requested local inspection without sending a model turn")
                    assert(readonly.queuedSubmission == nil && readonly.stopped.isEmpty && !readonly.sending)
                }
            }
        }
        assert(Bridge.steerCalls == 0)
        FixtureDefaults.standard.saved = nil
        assert(Model.newChatInitialAutonomy == "bypass")
        let freshSetup = Model.newChatDefaults(backends: [ChatBackend(id: "codex")])!
        assert(freshSetup.mode == "execute" && freshSetup.autonomy == "bypass",
               "Fresh local setup must show Execute/Don't ask before and after a catalog answers")
        FixtureDefaults.standard.saved = Data(#"{"backend":"codex","model":"model","effort":"high","mode":"plan","autonomy":"standard"}"#.utf8)
        assert(Model.newChatInitialAutonomy == "standard")
        let remembered = Model.newChatDefaults(backends: [ChatBackend(id: "codex")])!
        assert(remembered.mode == "execute" && remembered.autonomy == "standard" && remembered.model == "model",
               "An explicit remembered Ask first is preserved while Plan never becomes a fresh default")
        FixtureDefaults.standard.saved = nil
        let initial = Model()
        initial.busy = false; initial.attachments = []; initial.needsAuthentication = false
        initial.draft = "  Start from the landing page  "
        let emptyInitial = Model()
        emptyInitial.draft = ""
        await emptyInitial.sendInitialDraft()
        assert(emptyInitial.initialSends == 0 && emptyInitial.reservedInitialText == nil,
               "Open chat with an empty prompt cannot start a model turn")
        await initial.sendInitialDraft()
        assert(initial.initialSends == 1 && initial.reservedInitialText == "Start from the landing page",
               "Landing Send must use the existing composer reservation exactly once")
        let imageInitial = Model()
        imageInitial.busy = false; imageInitial.needsAuthentication = false; imageInitial.draft = ""
        await imageInitial.sendInitialDraft()
        assert(imageInitial.initialSends == 1 && imageInitial.reservedInitialText == "",
               "An attachment-only landing message must use the ordinary send reservation")
        let initialSignIn = Model()
        initialSignIn.busy = false; initialSignIn.attachments = []
        await initialSignIn.sendInitialDraft()
        assert(initialSignIn.signInQueuedMessage == true && initialSignIn.initialSends == 0,
               "Landing Send must preserve the existing sign-in hold")
        for commandName in ["/goal", "/plan", "/subagents"] {
            let readonly = Model()
            readonly.busy = false; readonly.attachments = []; readonly.draft = commandName
            await readonly.sendInitialDraft()
            assert(readonly.showingActivity && readonly.initialSends == 0 && readonly.reservedInitialText == nil,
                   "Landing read-only commands cannot become paid model messages")
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
        let shared = Model()
        shared.isSharedSource = true
        guard case .refused = shared.holdForSignIn(shared.draft, backend: "claude") else {
            fatalError("A shared chat cannot hold a personal sign-in send")
        }
        guard case .queue = shared.beginBusyNote(shared.draft) else { fatalError("A shared chat cannot steer") }
        assert(shared.busyNoteSubmission == nil)
        let reserved = Model()
        guard case let .steering(token) = reserved.beginBusyNote(reserved.draft) else { fatalError() }
        reserved.isSharedSource = true
        await reserved.finishBusyNote(token)
        assert(reserved.restoredDraft == "Add the highlighted detail" && Bridge.steerCalls == 0,
               "Sharing before the note lands restores the draft and never steers")
        let sharedLanding = Model()
        sharedLanding.isSharedSource = true
        sharedLanding.busy = false
        sharedLanding.attachments = []
        sharedLanding.needsAuthentication = false
        await sharedLanding.sendInitialDraft()
        assert(sharedLanding.initialSends == 0 && sharedLanding.reservedInitialText == nil,
               "A shared chat cannot start a landing turn")
        print("Steering submission: payload limits, attachment capability changes, reservation and stop-command ownership passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-steer-submission-') as work:
    work = Path(work)
    swift = work / 'Tests.swift'
    swift.write_text(activity_section + '\n' + stub + members + tests)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
        '-module-cache-path', str(work / 'cache'), '-o', str(work / 'test'), str(swift),
        str(root / 'apps/mac/Sources/Features/Work/WorkReference.swift'),
        str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatStartDraft.swift'),
        str(root / 'apps/mac/Sources/Features/Work/ChatDraftSubmission.swift'),
        str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatSteerContext.swift'),
        str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatCommandRules.swift')], check=True)
    subprocess.run([str(work / 'test')], check=True)
