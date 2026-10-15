#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production Mac opening methods against overlapping held replies."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
path = 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift'
source = (subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=root, text=True)
          if '--baseline' in sys.argv else (root / path).read_text())

def member(signature):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

methods = member('    private func openEvents(')
methods += '\n' + member('    private func loadEvents(')
methods += '\n' + member('    private func forgetWindow(')
methods += '\n' + member('    func reopenAtLatest(')
if '    private func readOpeningEvents(' in source:
    methods += '\n' + member('    private func readOpeningEvents(')

fixture = r'''import Foundation
struct Event: Sendable { let seq: UInt64? }
typealias ChatTimelineEvent = Event
@MainActor struct ChatReadingStore {
    static let shared = Self()
    func mark(for reference: Int) -> Int? { nil }
    func request(_ mark: Int, for reference: Int) {}
}
struct Page: Sendable {
    var events: [Event]; var nextOffset: UInt64 = 10; var tailCursor: String? = "tail"
    var cursor: String? = "earlier"; var hasEarlier = true; var historyTrimmed = false
    var usage: Int? = 1
    var reset = false
}
typealias ChatEventPage = Page
struct Conversation { var id = "A"; var sendRevision: UInt64? = 1; var title = "Demo" }
enum ChatPaging { static let openPageEvents = 1500 }
@MainActor enum Bridge {
    static var replies: [CheckedContinuation<Page, Error>?] = []
    static var tailCalls = 0
    static var tailFailure = false
    static var tailReset = false
    static func chatEventPage(id: String, cursor: String?, limit: Int, peer: String?) async throws -> Page {
        try await withCheckedThrowingContinuation { replies.append($0) }
    }
    static func finish(_ index: Int, seq: UInt64) {
        let held = replies[index]; replies[index] = nil
        held?.resume(returning: .init(events: [.init(seq: seq)]))
    }
    static func chatEvents(id: String, offset: UInt64, tailCursor: String?, peer: String?) async throws -> Page {
        tailCalls += 1
        if tailFailure { throw CocoaError(.fileReadUnknown) }
        return .init(events: [], reset: tailReset)
    }
    static func fail(_ index: Int) {
        let held = replies[index]; replies[index] = nil
        held?.resume(throwing: CocoaError(.fileReadUnknown))
    }
}
@MainActor final class Model {
    let openingRead = ChatOpeningRead<UInt64>()
    var generation: UInt64 = 1; var selected: Conversation? = .init(); var peer: String?
    var events: [Event] = [], eventsEpoch: UInt64 = 0, offset: UInt64 = 0
    var tailCursor: String?, earlierCursor: String?, windowReplacementTicket: UUID?
    var contextRevision: UInt64?, usageThrough: UInt64?, conversationUsage: Int?, savedCopy: Int?
    var error: String?, openingConversation = false
    var currentReference: Int?, readingRestorationPulse: UInt64 = 0
    var selectionGeneration: UInt64 { generation }
    var pagingUnavailable = false, hasEarlier = false, historyTrimmed = false, reachedStart = false, liveWindowLoaded = false
    var loadingEarlier = false, earlierInFlight = false
    var sending = false, sendingNow = false
    var outgoing: [String] = [], outgoingWatermark: [String: Int] = [:]
    func advanceSelection(_ reason: String) { openingRead.cancel(); generation &+= 1 }
    func discardSteerReservations() {}
    func selectionMatches(id: String, generation: UInt64) -> Bool { self.generation == generation && selected?.id == id }
    func beginWindowReplacement() -> UUID {
        let ticket = UUID(); windowReplacementTicket = ticket; eventsEpoch &+= 1; return ticket
    }
    func finishWindowReplacement(_ ticket: UUID) { if windowReplacementTicket == ticket { windowReplacementTicket = nil } }
    func publishEvents(id: String, generation: UInt64, canPublish: () -> Bool,
                       rebasesWindow: Bool = true, transform: ([Event]) -> [Event]) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation), canPublish() else { return false }
        events = transform(events); return true
    }
    func reconcileOutgoing() {}; func warmMarkdown() {}; func settleNotifications() {}
    func keepOfflineCopy(id: String, title: String?, page: Page, sendRevision: UInt64?) {}
    func scheduleResponseAttachments(id: String, generation: UInt64) {}
    func isUnknownMethod(_ error: Error) -> Bool { false }
METHODS
}
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<20000 { if condition() { return }; await Task.yield() }
    precondition(condition(), "Held request did not arrive")
}
@main struct Check {
    @MainActor static func main() async {
        let model = Model()
        let first = Task { await model.openEvents(id: "A", generation: 1) }
        await until { Bridge.replies.count == 1 }
        let second = Task { await model.openEvents(id: "A", generation: 1) }
        for _ in 0..<300 { await Task.yield() }
        second.cancel()
        let requests = Bridge.replies.count
        for i in Bridge.replies.indices { Bridge.finish(i, seq: 1) }
        let accepted = await first.value; _ = await second.value
        guard accepted, model.events.first?.seq == 1, requests == 1 else {
            print("FAIL: a cancelled overlapping open discarded the successful page (requests=\(requests), events=\(model.events.count))")
            exit(1)
        }
        // A new selection can open immediately while the old host is held.
        let stale = Task { await model.openEvents(id: "A", generation: 1) }
        await until { Bridge.replies.count == 2 }
        model.openingRead.cancel(); model.generation = 2; model.selected?.id = "B"
        let current = Task { await model.openEvents(id: "B", generation: 2) }
        await until { Bridge.replies.count == 3 }
        Bridge.finish(1, seq: 90); let staleAccepted = await stale.value
        precondition(!staleAccepted)
        Bridge.finish(2, seq: 2); let currentAccepted = await current.value
        precondition(currentAccepted && model.events.first?.seq == 2)
        // An interrupted first open is retried as a page, with paging metadata.
        model.liveWindowLoaded = false; model.events = []; model.offset = 0
        Bridge.tailFailure = true
        let offline = Task { await model.loadEvents(id: "B", reset: false, generation: 2, quiet: true) }
        await until { Bridge.replies.count == 4 }
        Bridge.fail(3); let failed = await offline.value
        precondition(!failed && !model.liveWindowLoaded && !model.openingConversation)
        Bridge.tailFailure = false; Bridge.tailCalls = 0
        let recovery = Task { await model.loadEvents(id: "B", reset: false, generation: 2, quiet: true) }
        await until { Bridge.replies.count == 5 }
        Bridge.finish(4, seq: 3); let recovered = await recovery.value
        precondition(recovered && model.liveWindowLoaded && model.hasEarlier && !model.openingConversation)
        precondition(Bridge.tailCalls == 0, "An unread selection incorrectly read the whole archive")
        let tail = await model.loadEvents(id: "B", reset: false, generation: 2, quiet: true)
        precondition(tail && Bridge.tailCalls == 1 && Bridge.replies.count == 5)
        // A reset on a full fallback cannot recursively await its own shared
        // opening flight. It must finish, allowing a later page retry.
        model.liveWindowLoaded = false
        Bridge.tailReset = true
        var resetCompleted = false
        let resetting = Task {
            let result = await model.loadEvents(id: "B", reset: false, generation: 2, quiet: true)
            resetCompleted = true
            return result
        }
        await until { Bridge.replies.count == 6 }
        Bridge.fail(5)
        for _ in 0..<20000 {
            if resetCompleted { break }
            await Task.yield()
        }
        guard resetCompleted else {
            print("FAIL: a resetting fallback awaited its own opening task")
            exit(1)
        }
        let resetAccepted = await resetting.value
        precondition(!resetAccepted && !model.openingConversation)
        Bridge.tailReset = false
        let retry = Task { await model.loadEvents(id: "B", reset: false, generation: 2, quiet: true) }
        await until { Bridge.replies.count == 7 }
        Bridge.finish(6, seq: 4)
        let retried = await retry.value
        precondition(retried && model.liveWindowLoaded && model.events.first?.seq == 4)
        // Send's follow pulse also returns long transcripts to the bottom.
        // That presentation change must not retire the in-flight send owner.
        model.sending = true
        var sendJumpFinished = false
        let sendJump = Task { await model.reopenAtLatest(); sendJumpFinished = true }
        await until { sendJumpFinished || Bridge.replies.count > 7 }
        precondition(sendJumpFinished && model.generation == 2 && Bridge.replies.count == 7
                     && model.events.first?.seq == 4 && model.contextRevision == 1,
                     "Jumping to the latest transcript invalidated an active send")
        await sendJump.value
        model.sending = false; model.sendingNow = true
        await model.reopenAtLatest()
        precondition(model.generation == 2 && Bridge.replies.count == 7,
                     "A pending-message send lost its selection during preparation")
        model.sendingNow = false
        // A cached selection in another project bypasses select(_:). Its
        // new window must discard the previous conversation's revision.
        model.contextRevision = 11
        model.forgetWindow()
        precondition(model.contextRevision == nil, "A replaced window retained another chat's send revision")
        model.selected = Conversation(id: "C", sendRevision: 0)
        model.generation = 3
        let switched = Task { await model.openEvents(id: "C", generation: 3) }
        await until { Bridge.replies.count == 8 }
        Bridge.finish(7, seq: 5)
        let switchedAccepted = await switched.value
        precondition(switchedAccepted && model.contextRevision == 0, "A new project must send with its own context")
        let idleJump = Task { await model.reopenAtLatest() }
        await until { Bridge.replies.count == 9 }
        precondition(model.generation == 4 && model.events.isEmpty && model.contextRevision == nil,
                     "An idle jump must still replace the old window")
        Bridge.finish(8, seq: 6)
        await idleJump.value
        precondition(model.liveWindowLoaded && model.events.first?.seq == 6 && model.contextRevision == 0)
        print("Chat opening: cancellation, selection fence, bounded recovery, tails, safe send jumps and project context passed")
    }
}
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-opening-') as directory:
    work = Path(directory)
    check = work / 'Check.swift'; check.write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(check), str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatPolling.swift'),
                    '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=30)
