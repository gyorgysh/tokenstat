#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production steering delivery with a turn ending during the RPC."""
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
    return source[start:end].replace('ChatOutboxStore.shared', 'outbox')


members = '\n'.join(member(signature) for signature in [
    '    private var queueHead:', '    var queuePaused:', '    private var ownsQueue:',
    '    func drainQueue(', '    private func deliverQueued(',
])

fixture = r'''
import Foundation
struct ChatAttachment: Codable, Equatable, Sendable { let id: String; let name: String }
struct ChatConversation {
    var id = "chat", backend = "codex"
    var running = true
    var sendRevision: UInt64? = 7
    var pendingSteer: String? = nil
    var nativeSteer = true
}
struct ChatBackend {
    var id = "codex", canCheckSignIn = false
    var signInFlow: SignInFlow? = nil
    struct SignInFlow { var supported = false }
}
struct SignInStatus { var checked = false; var readiness: String? = nil }
enum BridgeError: Error, LocalizedError {
    case core(code: String, message: String)
    var errorDescription: String? { switch self { case .core(_, let message): return message } }
}
struct Receipt {
    enum State { case missing, needsRecovery }
    var isAccepted = false
    var state = State.missing
}
enum L10n { static func text(_ key: String) -> String { key } }
enum WorkCacheAccess {
    static func canSave(_ reference: WorkReference) -> Bool { true }
    static func canRead(_ reference: WorkReference) -> Bool { true }
}
@MainActor enum Bridge {
    struct Send {
        let steering: Bool
        let id: String?
        let created: Date?
        let revision: UInt64?
        let text: String
        let files: [String]
    }
    static var sends: [Send] = []
    static var failure: BridgeError? = .core(code: "steer_unavailable", message: "turn ended")
    static var refusalsRemaining = Int.max
    static var hostRunning = true
    static var hostNative = true
    static var statusFails = false
    static var beforeReply: (() -> Void)?
    static func reset(running: Bool = true, code: String = "steer_unavailable") {
        sends = []; hostRunning = running; beforeReply = nil
        hostNative = true; statusFails = false
        refusalsRemaining = Int.max
        failure = .core(code: code, message: "controlled refusal")
    }
    static func workspaceAccessAllowed(peer: String) async throws -> Bool { true }
    static func chats(workspaceID: String, peer: String?) async throws -> [ChatConversation] {
        if statusFails { throw BridgeError.core(code: "offline", message: "status unavailable") }
        return [ChatConversation(running: hostRunning, nativeSteer: hostNative)]
    }
    static func chatReceipt(id: String, clientMessageID: String, peer: String?) async throws -> Receipt { Receipt() }
    static func isDeliveryUnknown(_ error: Error) -> Bool {
        if case BridgeError.core(code: "delivery_unknown", message: _) = error { return true }
        return false
    }
    static func sendChat(id: String, text: String, attachmentIDs: [String], clientMessageID: String?,
                         clientMessageCreatedAt: Date?, expectedRevision: UInt64?, steer: Bool,
                         peer: String?) async throws -> ChatConversation {
        sends.append(Send(steering: steer, id: clientMessageID, created: clientMessageCreatedAt,
                          revision: expectedRevision, text: text, files: attachmentIDs))
        beforeReply?()
        if steer, let failure, refusalsRemaining > 0 {
            refusalsRemaining -= 1
            throw failure
        }
        return ChatConversation(running: true, sendRevision: expectedRevision.map { $0 + (steer ? 0 : 1) })
    }
}
@MainActor final class Model {
    let outbox: ChatOutboxStore
    let queuedReference: WorkReference?
    var currentReference: WorkReference?
    var queued: [ChatQueuedMessage]
    var authorizedQueueItems: Set<String> = ["message"]
    var selected: ChatConversation? = ChatConversation()
    var chats: [ChatConversation] = [ChatConversation()]
    var savedCopy: Bool? = nil
    var peer: String? = "host"
    var selectionGeneration: UInt64 = 1
    var contextRevision: UInt64? = 7
    var sending = false, sendingNow = false
    var deliveringSteer: Int? = nil, clearingSteer: Int? = nil
    var error: String? = nil
    var polls = 0, stops = 0
    var busy: Bool { selected?.running == true }
    var nativeSteerAcceptsAttachments = true
    init(directory: URL) throws {
        outbox = ChatOutboxStore(directory: directory)
        let reference = WorkReference(scope: .local(installationID: "fixture"), hostIdentity: "host",
                                      workspaceID: "workspace", kind: .conversation, itemID: "chat")
        queuedReference = reference; currentReference = reference
        var item = ChatQueuedMessage(id: "message", text: "Keep going with these details",
                                     attachments: [ChatAttachment(id: "image", name: "image.png")])
        item.expectedRevision = 7
        queued = try outbox.update(reference) { $0 = [item] }
    }
    func send() async -> Bool { await deliverQueued(queued[0], stopCurrent: false, steerCurrent: true) }
    func rows() throws -> [ChatQueuedMessage] { try outbox.items(for: queuedReference!) }
    func noteSendStarted() -> UInt64 { sending = true; return 1 }
    func noteSendFinished(_ token: UInt64) { sending = false }
    func selectionMatches(id: String, generation: UInt64) -> Bool {
        selected?.id == id && selectionGeneration == generation
    }
    func machineConfirmsSends(peer: String?, checkingReceipt: Bool) async throws -> Bool { true }
    func clearSubmittedDraft(_ item: ChatQueuedMessage, reference: WorkReference) {}
    func loadEvents(id: String, reset: Bool, generation: UInt64) async {}
    func stop() async { stops += 1; selected?.running = false }
    func poll() async { polls += 1; selected?.running = Bridge.hostRunning }
    func beginChatListRead(workspaceID: String, peer: String?) -> Int? { polls += 1; return polls }
    func applyChatList(_ rows: [ChatConversation], read: Int?, current: [ChatConversation]) -> [ChatConversation] { rows }
    func busyTurnError() { error = "busy" }
    func backend(for id: String) -> ChatBackend? { nil }
    func checkSignIn(_ backend: ChatBackend) async -> SignInStatus? { nil }
    func resolveDraftAttachments(_ files: [ChatAttachment], reference: WorkReference,
                                 peer: String?) async throws -> [ChatAttachment] { files }
    func stageOutgoing(_ text: String, steer: Bool) -> Int { 1 }
    func dropOutgoing(_ staged: Int) {}
    func replace(_ updated: ChatConversation) { selected = updated; chats = [updated] }
MEMBERS
}
@main enum Tests {
    @MainActor static func settle() async throws {
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        Bridge.reset()
        Bridge.failure = nil
        let active = try Model(directory: directory.appendingPathComponent("active"))
        let accepted = await active.send()
        let activeEmpty = try active.rows().isEmpty
        assert(accepted && activeEmpty && Bridge.sends.count == 1 && Bridge.sends[0].steering)
        assert(active.busy && active.contextRevision == 7 && active.stops == 0 && active.polls == 0,
               "A live steer must reach the active turn without starting or stopping a turn")
        Bridge.reset()
        let ongoing = try Model(directory: directory.appendingPathComponent("ongoing"))
        _ = await ongoing.send()
        try await settle()
        let waiting = try ongoing.rows().first!
        assert(waiting.delivery == .waiting && waiting.attemptedAt == nil,
               "A definitely refused steer must remain authorized and waiting, not fail")
        assert(ongoing.authorizedQueueItems.contains(waiting.id) && ongoing.error == nil)
        assert(Bridge.sends.count == 2 && Bridge.sends.allSatisfy(\.steering) && ongoing.stops == 0,
               "A fresh live capability allows one retry, never an interruption or a retry loop")
        Bridge.hostRunning = false
        await ongoing.poll()
        await ongoing.drainQueue()
        let ongoingEmpty = try ongoing.rows().isEmpty
        assert(ongoingEmpty)
        assert(Bridge.sends.count == 3 && !Bridge.sends[2].steering && ongoing.stops == 0)
        assert(Bridge.sends[0].id == Bridge.sends[2].id
               && Bridge.sends[0].created == Bridge.sends[2].created
               && Bridge.sends[0].revision == Bridge.sends[2].revision
               && Bridge.sends[0].files == Bridge.sends[2].files
               && Bridge.sends[0].text == Bridge.sends[2].text,
               "The next normal send must retain the exact writing, files, context and receipt identity")
        Bridge.reset()
        Bridge.refusalsRemaining = 1
        let resumed = try Model(directory: directory.appendingPathComponent("resumed"))
        _ = await resumed.send()
        try await settle()
        let resumedEmpty = try resumed.rows().isEmpty
        assert(resumedEmpty && resumed.busy && resumed.stops == 0
               && Bridge.sends.count == 2 && Bridge.sends.allSatisfy(\.steering),
               "A freshly confirmed active turn must receive the steer as live input")
        for unavailableStatus in [false, true] {
            Bridge.reset()
            Bridge.statusFails = unavailableStatus
            Bridge.hostNative = false
            let unconfirmed = try Model(directory: directory.appendingPathComponent("status-\(unavailableStatus)"))
            _ = await unconfirmed.send()
            try await settle()
            let row = try unconfirmed.rows().first!
            assert(row.delivery == .waiting && Bridge.sends.count == 1 && unconfirmed.stops == 0,
                   "A failed refresh or absent fresh live capability cannot authorize a retry")
        }
        Bridge.reset(running: false)
        let ended = try Model(directory: directory.appendingPathComponent("ended"))
        _ = await ended.send()
        try await settle()
        let endedEmpty = try ended.rows().isEmpty
        assert(endedEmpty)
        assert(Bridge.sends.count == 2 && !Bridge.sends[1].steering && ended.stops == 0,
               "A fresh idle report must release the refused message exactly once")
        for code in ["delivery_unknown", "steer_refused", "conversation_changed"] {
            Bridge.reset(running: false, code: code)
            let held = try Model(directory: directory.appendingPathComponent(code))
            _ = await held.send()
            try await settle()
            await held.poll(); await held.drainQueue()
            let row = try held.rows().first!
            assert(row.delivery == (code == "delivery_unknown" ? .deliveryUnknown
                                    : code == "conversation_changed" ? .needsReview : .failed))
            assert(Bridge.sends.count == 1 && held.stops == 0,
                   "Uncertain delivery, rejected content and changed context cannot trigger a resend")
        }
        Bridge.reset(running: false)
        let moved = try Model(directory: directory.appendingPathComponent("moved"))
        Bridge.beforeReply = {
            moved.selectionGeneration += 1
            moved.currentReference = WorkReference(scope: .local(installationID: "other"),
                hostIdentity: "other", workspaceID: "other", kind: .conversation, itemID: "other")
            moved.selected?.id = "other"
            moved.authorizedQueueItems = []
        }
        _ = await moved.send()
        try await settle()
        assert(Bridge.sends.count == 1 && moved.polls == 0 && moved.authorizedQueueItems.isEmpty,
               "A late refusal cannot send, refresh or authorize another chat or account")
        let movedWaiting = try moved.rows().first?.delivery == .waiting
        assert(movedWaiting)
        for removed in [false, true] {
            Bridge.reset(running: false)
            let changed = try Model(directory: directory.appendingPathComponent("changed-\(removed)"))
            Bridge.beforeReply = {
                _ = try! changed.outbox.update(changed.queuedReference!) { rows in
                    if removed { rows.removeAll() }
                    else { rows[0].delivery = .deliveryUnknown }
                }
            }
            _ = await changed.send()
            try await settle()
            let rows = try changed.rows()
            assert(removed ? rows.isEmpty : rows.first?.delivery == .deliveryUnknown)
            assert(Bridge.sends.count == 1 && changed.authorizedQueueItems.isEmpty,
                   "A late refusal cannot recreate removed writing or overwrite a receipt hold")
        }
        print("Steering delivery: ended/ongoing turns, exact payload, uncertain receipts and navigation passed")
    }
}
'''.replace('MEMBERS', members)

with tempfile.TemporaryDirectory(prefix='tokenstat-steer-delivery-') as work:
    work = Path(work)
    swift = work / 'Tests.swift'
    swift.write_text(fixture)
    sources = root / 'apps/mac/Sources'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    '-module-cache-path', str(work / 'cache'), '-o', str(work / 'test'), str(swift),
                    str(sources / 'Features/Work/WorkReference.swift'),
                    str(sources / 'Features/Work/ChatOutboxStore.swift'),
                    str(sources / 'Features/Work/OriginalFileCoordination.swift'),
                    str(sources / 'Features/Workspaces/Chat/ChatCommandRules.swift')], check=True)
    subprocess.run([str(work / 'test')], check=True)
