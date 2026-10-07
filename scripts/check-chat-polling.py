#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise real ChatModel polling/scheduling with suspended transport replies."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
def member(signature):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func').replace('private var', 'var')
names = ['private func pollIsCurrent(', 'private func cancelPollReads(', 'func poll(',
         'private func startStatusPoll(', 'private func startApprovalPoll(',
         'private func performStatusPoll(', 'private func refreshUsage(', 'private func loadApprovals(',
         'private func scheduleResponseAttachments(', 'private var responseAttachmentDescriptors:',
         'private func loadResponseAttachments(', 'private func loadResponseAttachment(',
         'private func noteSteerAvailability(']
methods = '\n'.join(member('    ' + name) for name in names)
# Substitute only the monotonic clock, allowing metadata ticks without wall-clock sleeps.
methods = methods.replace('ProcessInfo.processInfo.systemUptime', 'clock')
# Count actual getter rebuilds; event access also occurs in metadata hint inspection.
methods = methods.replace('if attachmentDescriptorRevision != eventsRevision {', 'if attachmentDescriptorRevision != eventsRevision {\n            descriptorScans += 1')
assert 'await loadResponseAttachments' not in member('    private func loadEvents(')
assert '!Task.isCancelled' in member('    private func noteSteerAvailability(')
for path in ['apps/mac/Sources/Features/Workspaces/Chat/ChatView.swift', 'apps/mac/Sources/Client/ClientChatView.swift']:
    view = (root / path).read_text()
    assert '.transcriptFollowBar {' in view
    assert 'model.approvals.isEmpty && (follow.showJump || model.busy)' in view
    assert 'await model.watchPolls()' in view and 'ChatPollWatchIdentity(owner: model.pollingIdentity' in view
swift = r'''import Foundation
@MainActor final class Context { static let shared = Context(); var scope = "A" }
struct Reference: Hashable, Sendable { let scope: String; let workspaceID = "work"; let itemID: String? = "chat" }
struct ChatConversation: Equatable { let id: String; var running: Bool }
struct ChatAttachment { let id: String; let name: String; let mediaType: String?; let size: UInt64? }
struct Event { var kind: String; var id: String?; var name: String?; var mediaType: String?; var size: UInt64? }
@MainActor struct ChatTimelineEvent {
    var kind: String; let stored: Event?; var seq: UInt64? = 1
    var event: Event? { Bridge.descriptorReads += 1; return stored }
}
struct Usage { let isValid = true }
struct Page { let usage: Usage? = Usage(); let events: [ChatTimelineEvent] = [] }
struct Payload { let data: String }
@MainActor final class Wire {
    var calls = 0
    var held: [CheckedContinuation<Void, Error>?] = []
    func read() async throws { calls += 1; try await withCheckedThrowingContinuation { held.append($0) } }
    func finish(_ i: Int, fail: Bool = false) {
        let c = held[i]; held[i] = nil
        if fail { c?.resume(throwing: CocoaError(.fileReadUnknown)) } else { c?.resume() }
    }
}
@MainActor enum Bridge {
    static let status = Wire(), approvals = Wire(), usage = Wire(), attachments = Wire(), capability = Wire()
    static var statusReply = [ChatConversation(id: "chat", running: true)]
    static var approvalReply = ["approval"], descriptorReads = 0
    static func peerProtocolVersion(_ peer: String) async throws -> Int { try await capability.read(); return 99 }
    static func chats(workspaceID: String, peer: String?) async throws -> [ChatConversation] { try await status.read(); return statusReply }
    static func chatApprovals(id: String, peer: String?) async throws -> [String] { try await approvals.read(); return approvalReply }
    static func chatEventPage(id: String, cursor: String?, limit: Int, peer: String?) async throws -> Page { try await usage.read(); return Page() }
    static func chatAttachment(id: String, attachmentID: String, peer: String?) async throws -> Payload { try await attachments.read(); return Payload(data: Data("file".utf8).base64EncodedString()) }
}
@MainActor enum WorkCacheAccess { static func canRead(_ r: Reference) -> Bool { r.scope == Context.shared.scope }; static func canSave(_ r: Reference) -> Bool { canRead(r) } }
@MainActor enum WorkSavedPreview {
    static func read(reference: Reference, attachment: String) async -> Data? { nil }
    static func save(reference: Reference, attachment: ChatAttachment, data: Data) async {}
}
@MainActor final class ChatAttachmentCache {
    static let shared = ChatAttachmentCache()
    func epoch() async -> UInt64 { 0 }
    func read(reference: Reference, attachment: String) async -> Data? { nil }
    func write(_ data: Data, reference: Reference, attachment: String, epoch: UInt64) async -> Bool { WorkCacheAccess.canSave(reference) }
}
enum RemoteHostFeature { case steer; var minimumProtocol: Int { 1 } }
enum ChatInbox { static let maxBytes = 100 }
enum ChatAttachmentDownloadPolicy { static func permitsAutomaticDownload(size: UInt64?) -> Bool { true } }
@MainActor enum ClientChatReadState { static let shared = SelfHolder(); final class SelfHolder { func markRead(peer: String?, chat: ChatConversation) {} } }
@MainActor final class Model {
    struct PollOwner: Hashable, Sendable { let reference: Reference; let generation: UInt64 }
    var currentReference: Reference? = Reference(scope: "A"), selectionGeneration: UInt64 = 1
    var selected: ChatConversation? = ChatConversation(id: "chat", running: true)
    var pollingIdentity: PollOwner? { guard savedCopy == nil, let reference = currentReference, reference.scope == Context.shared.scope else { return nil }; return .init(reference: reference, generation: selectionGeneration) }
    let eventPollLane = ChatPollLane<PollOwner>(), statusPollLane = ChatPollLane<PollOwner>(), approvalPollLane = ChatPollLane<PollOwner>(), attachmentPollLane = ChatPollLane<PollOwner>()
    var pollCadence = ChatPollCadence(), cadenceOwner: PollOwner?, clock = 0.0
    var openingConversation = false, savedCopy: Bool?, peer: String?, folderID: String?
    var chats: [ChatConversation] = [], approvals: [String] = [], approvalsLoaded = false, error: String?
    var events: [ChatTimelineEvent] = [] { didSet { eventsRevision &+= 1 } }
    var eventsRevision: UInt64 = 0, attachmentCacheGeneration: UInt64 = 0
    var attachmentDescriptorRevision: UInt64?, attachmentDescriptors: [ChatAttachment] = []; var descriptorScans = 0
    var attemptedResponseAttachments: Set<String> = [], loadingResponseAttachments: Set<String> = []
    var responseAttachmentData: [String: Data] = [:], responseAttachmentErrors: [String: String] = [:]
    var conversationUsage: Usage?, usageThrough: UInt64?
    var deliveringSteer: String?, deliveringSteerToken: UInt64?
    let eventWire = Wire(); var fresh: [ChatTimelineEvent] = []
    func loadEvents(id: String, reset: Bool, generation: UInt64, quiet: Bool, onFreshEvents: (([ChatTimelineEvent]) -> Void)?) async -> Bool {
        do { try await eventWire.read() } catch { return false }
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        onFreshEvents?(fresh); events += fresh; return true
    }
    func selectionMatches(id: String, generation: UInt64) -> Bool { selectionGeneration == generation && selected?.id == id && currentReference?.scope == Context.shared.scope }
    func beginChatListRead(workspaceID: String, peer: String?) -> Int { 0 }
    func applyChatList(_ answer: [ChatConversation], read: Int, current: [ChatConversation]) -> [ChatConversation] { answer }
    func storeChatListCache(_ chats: [ChatConversation], folderID: String) {}
    func settleNotifications() {}
    var pendingClaim: String?, deliveries: [UInt64] = [], finishes: [UInt64] = []
    func claimSteerDelivery() -> String? {
        guard let pendingClaim else { return nil }
        self.pendingClaim = nil; deliveringSteer = pendingClaim; deliveringSteerToken = 1
        return pendingClaim
    }
    var busy: Bool { selected?.running == true }
    var remoteSteer: Bool?, steerProbeStarted = false, steerProbeTicket: UUID?, steerProbeOwner: PollOwner?
    func performSteerDelivery(_ item: String) async { deliveries.append(deliveringSteerToken ?? 0) }
    func finishSteerDelivery(_ item: String, token: UInt64) {
        finishes.append(token)
        if deliveringSteer == item && deliveringSteerToken == token { deliveringSteer = nil; deliveringSteerToken = nil }
    }
    static func downloadFailure(_ error: Error) -> String { "failure" }
''' + methods + r'''
}
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<20000 { if condition() { return }; await Task.yield() }
    precondition(condition(), "Controlled read did not arrive")
}
@main struct Check {
    @MainActor static func main() async {
        let m = Model()
        // Actual model ticks keep event/status/approval requests bounded.
        for _ in 0..<30 { await m.poll(forceStatus: false) }
        await until { m.eventWire.calls == 1 && Bridge.status.calls == 1 && Bridge.approvals.calls == 1 }
        Bridge.status.finish(0); Bridge.approvals.finish(0)
        await until { m.approvalsLoaded }
        // A new approval arrives while the event request remains suspended.
        m.clock = 1.1; Bridge.approvalReply = ["late"]
        await m.poll(forceStatus: false)
        await until { Bridge.status.calls == 2 && Bridge.approvals.calls == 2 }
        precondition(m.eventWire.calls == 1)
        Bridge.status.finish(1); Bridge.approvals.finish(1)
        await until { m.approvals == ["late"] }
        // A fresh done record wakes metadata immediately, without guessing running=false.
        m.fresh = [.init(kind: "agent", stored: .init(kind: "done"))]
        m.eventWire.finish(0)
        await until { Bridge.status.calls == 3 && Bridge.approvals.calls == 3 }
        precondition(m.selected?.running == true)
        Bridge.status.finish(2); Bridge.approvals.finish(2)
        await until { m.eventsRevision == 1 }
        for _ in 0..<100 { await Task.yield() }
        // Account retirement fences both successful and failed late replies.
        m.clock = 3; await m.poll(forceStatus: false)
        await until { m.eventWire.calls == 2 && Bridge.status.calls == 4 && Bridge.approvals.calls == 4 }
        let old = m.pollingIdentity!
        m.cancelPollReads(owner: old); Context.shared.scope = "B"
        Bridge.statusReply = [.init(id: "chat", running: false)]; Bridge.approvalReply = ["wrong account"]
        m.eventWire.finish(1); Bridge.status.finish(3); Bridge.approvals.finish(3, fail: true)
        for _ in 0..<100 { await Task.yield() }
        precondition(m.selected?.running == true && m.approvals == ["late"] && m.events.count == 1 && m.error == nil)
        Context.shared.scope = "A"
        // Usage awaits cannot publish once a status refresh retires them.
        var permits = true
        let usage = Task { await m.refreshUsage(id: "chat", generation: 1, permitsPublication: { permits }) }
        await until { Bridge.usage.calls == 1 }; permits = false; Bridge.usage.finish(0); await usage.value
        precondition(m.conversationUsage == nil && m.usageThrough == nil)
        let canceledUsage = Task { await m.refreshUsage(id: "chat", generation: 1) }
        await until { Bridge.usage.calls == 2 }; canceledUsage.cancel(); Bridge.usage.finish(1); await canceledUsage.value
        precondition(m.conversationUsage == nil)

        // Actual descriptor getter/scheduler: unchanged history scans once.
        Bridge.statusReply = [.init(id: "chat", running: true)]
        let files = Model(); files.events = (0..<2000).map { _ in .init(kind: "agent", stored: .init(kind: "text")) }
        Bridge.descriptorReads = 0
        for _ in 0..<30 { files.scheduleResponseAttachments(id: "chat", generation: 1) }
        precondition(files.descriptorScans == 1 && Bridge.attachments.calls == 0)
        files.events.append(.init(kind: "agent", stored: .init(kind: "attachment", id: "file", name: "f", size: 1)))
        files.scheduleResponseAttachments(id: "chat", generation: 1)
        await until { Bridge.attachments.calls == 1 }
        let scans = files.descriptorScans
        for _ in 0..<30 { files.scheduleResponseAttachments(id: "chat", generation: 1) }
        precondition(files.descriptorScans == scans)
        files.attachmentPollLane.cancel(); Bridge.attachments.finish(0)
        await until { !files.loadingResponseAttachments.contains("file") }
        precondition(!files.attemptedResponseAttachments.contains("file") && files.responseAttachmentData.isEmpty)
        // Real foreground poll retries the file even while its event read hangs.
        await files.poll(forceStatus: false)
        await until { Bridge.attachments.calls == 2 && files.eventWire.calls == 1 && Bridge.status.calls == 5 && Bridge.approvals.calls == 5 }
        Bridge.status.finish(4); Bridge.approvals.finish(4)
        // Conversely, text publishes while the file response remains held.
        files.fresh = [.init(kind: "agent", stored: .init(kind: "text"))]
        files.eventWire.finish(0)
        await until { files.events.count == 2002 }
        precondition(files.responseAttachmentData.isEmpty && Bridge.attachments.calls == 2)
        Bridge.attachments.finish(1)
        await until { files.responseAttachmentData["file"] != nil }
        precondition(files.descriptorScans == scans + 1, "Unchanged polling rescanned descriptor history")
        files.cancelPollReads(); files.eventWire.finish(0)
        // Actual capability method: same reader can retry after canceled view;
        // predecessor success/error cannot publish or release the new ticket.
        let probes = Model(); probes.peer = "host"
        let first = Task { await probes.noteSteerAvailability() }
        await until { Bridge.capability.calls == 1 }
        probes.cancelPollReads(owner: probes.pollingIdentity!); first.cancel()
        let second = Task { await probes.noteSteerAvailability() }
        await until { Bridge.capability.calls == 2 }
        Bridge.capability.finish(0); await first.value
        precondition(probes.remoteSteer == nil && probes.steerProbeStarted)
        Bridge.capability.finish(1); await second.value
        precondition(probes.remoteSteer == true && !probes.steerProbeStarted)
        probes.remoteSteer = nil
        let third = Task { await probes.noteSteerAvailability() }
        await until { Bridge.capability.calls == 3 }
        probes.cancelPollReads(); third.cancel()
        let fourth = Task { await probes.noteSteerAvailability() }
        await until { Bridge.capability.calls == 4 }
        Bridge.capability.finish(2, fail: true); await third.value
        precondition(probes.remoteSteer == nil && probes.steerProbeStarted)
        Bridge.capability.finish(3); await fourth.value
        precondition(probes.remoteSteer == true && !probes.steerProbeStarted)
        // Actual status method captures the delivery token before probing.
        let reserved = Model(); reserved.peer = "host"; reserved.pendingClaim = "note"
        let status = Task { await reserved.performStatusPoll(owner: reserved.pollingIdentity!, permitsPublication: { true }) }
        await until { Bridge.status.calls == 6 }; Bridge.status.finish(5)
        await until { Bridge.capability.calls == 5 }
        reserved.deliveringSteerToken = 2 // successor owns the same note context
        Bridge.capability.finish(4); await status.value
        precondition(reserved.deliveries.isEmpty && reserved.finishes.isEmpty && reserved.deliveringSteerToken == 2)
        let canceledReservation = Model(); canceledReservation.peer = "host"; canceledReservation.pendingClaim = "note"
        let canceledStatus = Task { await canceledReservation.performStatusPoll(owner: canceledReservation.pollingIdentity!, permitsPublication: { true }) }
        await until { Bridge.status.calls == 7 }; Bridge.status.finish(6)
        await until { Bridge.capability.calls == 6 }; canceledStatus.cancel()
        Bridge.capability.finish(5); await canceledStatus.value
        precondition(canceledReservation.deliveries.isEmpty && canceledReservation.finishes == [1] && canceledReservation.deliveringSteerToken == nil)
        print("ChatModel: held events allow metadata, terminal wake, scoped late replies, usage fences, cached descriptor scans, attachment retry")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'), str(work / 'Check.swift'), str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatPolling.swift'), str(root / 'apps/mac/Sources/Design/L10n.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
