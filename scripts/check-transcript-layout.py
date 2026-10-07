#!/usr/bin/env python3
"""Check transcript follow and deferred scrolling using the production Swift types.

Run on macOS with the Swift toolchain. No app, host daemon, or signing needed.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "apps/mac/Sources/Features/Workspaces/Chat/TranscriptFollow.swift").read_text()
metrics = source[source.index("struct TranscriptMetrics:"):source.index("@available(macOS 15.0")]
follow = source[source.index("@Observable\nfinal class TranscriptFollowState"):source.index("struct ChatScrollContentKey:")]
delivery = source[source.index("final class TranscriptScrollDelivery"):source.index("/// Report where the transcript is scrolled,")]
slice = source[source.index("enum TranscriptSlice"):source.index("struct TranscriptMetrics:")]
tests = r'''
func metrics(_ top: CGFloat, _ height: CGFloat = 1000) -> TranscriptMetrics {
    TranscriptMetrics(distanceFromTop: top, distanceFromBottom: height - top - 400,
                      contentHeight: height, viewportHeight: 400)
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
let delivery = TranscriptScrollDelivery()
var received: [Int] = []
for value in 0..<100 { delivery.submit { received.append(value) } }
assert(received.isEmpty, "must not scroll inside the geometry callback")
drain()
assert(received == [99], "only the newest pending correction should execute")
var depth = 0
var maxDepth = 0
func receive(_ value: Int) {
    depth += 1
    maxDepth = max(depth, maxDepth)
    received.append(value)
    if value == 100 { delivery.submit { receive(101) } }
    depth -= 1
}
delivery.submit { receive(100) }
drain()
assert(received == [99, 100, 101] && maxDepth == 1, "corrections must not re-enter layout")
delivery.submit { receive(102) }
delivery.cancel()
drain()
assert(received == [99, 100, 101], "cancelled corrections must not execute")
delivery.submit { receive(103) }
drain()
assert(received.last == 103, "delivery must work after cancellation")

for driven in [false, true] {
    let state = TranscriptFollowState()
    state.note(metrics(600))
    if driven { state.markDriven() }
    state.note(metrics(500))
    assert(!state.pinned && state.showJump, "one wheel tick must release follow")
}
let growth = TranscriptFollowState()
growth.note(metrics(600))
var repins = 0
growth.repin = { repins += 1; return true }
growth.note(metrics(600, 1100))
assert(growth.pinned && repins == 0, "growth must queue a correction without scrolling inline")
drain()
assert(repins == 1, "stationary growth must still follow")

let departed = TranscriptFollowState()
departed.note(metrics(600))
var unwanted = 0
departed.repin = { unwanted += 1; return true }
departed.note(metrics(600, 1100))
departed.note(metrics(500, 1100))
assert(!departed.pinned, "user motion must be tracked before deferred corrections execute")
drain()
assert(unwanted == 0, "a queued correction must not pull back a reader who left")

let paused = TranscriptFollowState()
paused.note(metrics(600))
paused.repin = { unwanted += 1; return true }
paused.note(metrics(600, 1100))
paused.pause()
drain()
assert(unwanted == 0, "pause must cancel pending corrections")

let estimate = TranscriptFollowState()
estimate.note(metrics(600))
estimate.note(metrics(500, 1100))
assert(estimate.pinned, "a single lazy-height correction must not release follow")

let restored = TranscriptFollowState()
restored.note(metrics(600))
restored.settle(true)
restored.pinned = false
restored.markDrivenInstant()
restored.note(metrics(500))
assert(!restored.abandoned, "measured reading restoration must not abandon itself")
restored.markDriven(duration: -1)
restored.note(metrics(400))
assert(restored.abandoned, "reader movement must still interrupt reading restoration")

let hidden = TranscriptFollowState()
hidden.note(metrics(600))
hidden.sliceHidesNewest = true
hidden.note(metrics(0, 400))
assert(!hidden.pinned && hidden.showJump, "a slice that hid the newest rows is not the end")

assert(TranscriptSlice.range(count: 10, olderOffset: 0) == 0..<10, "short lists are the whole list")
assert(TranscriptSlice.range(count: 200, olderOffset: 0) == 50..<200, "glued to the end is a suffix")
assert(TranscriptSlice.range(count: 200, olderOffset: 50) == 0..<150, "full slide reaches the start")
assert(TranscriptSlice.hiddenAbove(count: 200, olderOffset: 0) == 50, "suffix hides the prefix")
assert(TranscriptSlice.revealingEarlier(count: 200, olderOffset: 0) == 50, "one tap cannot overshoot")
assert(TranscriptSlice.clampOffset(999, count: 200) == 50, "offset cannot exceed the slice")
let ids = (0..<200).map { ChatDisplayItem(id: "\($0)") }
assert(TranscriptSlice.holding("0", in: ids, current: 50) == 50, "holding the first visible row keeps the start")
let grown = (0..<210).map { ChatDisplayItem(id: "\($0)") }
assert(TranscriptSlice.holding("0", in: grown, current: 50) == 60, "a turn below must not slide the window")
let earlier = (0..<100).map { ChatDisplayItem(id: "p\($0)") } + ids
assert(TranscriptSlice.holding("0", in: earlier, current: 50) == 50, "a page above must not replace the window")
assert(TranscriptSlice.range(count: 300, olderOffset: 50) == 100..<250, "held offset after a prepend is the original rows")
assert(TranscriptSlice.holding("missing", in: ids, current: 50) == 50, "a gone row keeps the last offset")
print("PASS: deferred/coalesced corrections, no re-entry, cancellation, wheel gestures, growth, departure, pause, estimate resizing, hidden slice, bounded window")
'''
with tempfile.TemporaryDirectory(prefix="tokenstat-layout-test-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(
        "import Foundation\nimport Observation\n"
        "enum TranscriptFollow { static let threshold: CGFloat = 56 }\n"
        "struct ChatDisplayItem: Identifiable { let id: String }\n"
        + slice + metrics + delivery + follow + tests
    )
    subprocess.run(["swift", str(path)], check=True)

mobile = (root / "apps/mac/Sources/Client/ClientChatView.swift").read_text()
assert "keepViewport(allowLatest:" not in mobile, "outgoing layouts must not sample transitional rows"
assert "generation == model.selectionGeneration, readerMoved," in mobile, "programmatic settling must not persist reader geometry"
assert "readerInitiated: readerMoved" in mobile, "only a reader or explicit row action replaces the kept viewport"
assert "guard position != .unknown else { return }" in mobile, "unmeasured geometry must retain permission for a fresh sample"
assert "TranscriptReading.record(position, for: model.currentReference)" in mobile, "durable and live reading stores must receive one sample"
assert "view.bounds.inset(by: view.adjustedContentInset)" in mobile, "reading must use the dynamically inset native viewport"
assert "reporter.window === window" in mobile, "coordinate conversion must use the local reporter's own window"
assert "reporterGlobalFrame" not in mobile, "moving calibration and row frames must arrive in one preference payload"
assert "captureID == readingFrames.captureID" in mobile, "a newer gesture must retire an old capture retry"
assert "readingDelivery.submit" in mobile, "passive reading corrections must be deferred and coalesced"
assert "if watched || holdingReading" in mobile, "reading geometry must survive programmatic reflow independently of paging"
assert "ticket == settleTaskID" in mobile, "same-presentation restoration predecessors must not mutate a successor"
assert "viewportContinuity.claim(" not in mobile, "onAppear must not let an unattached presentation steal the viewport"
placement_task = mobile[mobile.index('.task(id: ClientChatViewportTaskIdentity('):mobile.index('.task(id: settleMood)')]
assert "attachment: scrollAccess.attachmentIdentity" in placement_task and "vacancy: model.viewportContinuity.vacancy" in placement_task, "real attachment and owner vacancy must wake restoration"
assert placement_task.index("scrollAccess.matches(attachment)") < placement_task.index("viewportContinuity.beginPlacement"), "attachment must be verified before acquiring a lease"
assert "eligible: scrollAccess.matches(attachment)" in placement_task, "actual acquisition must deny unattached/hidden candidates"
restore_source = mobile[mobile.index('private func restoreReadingPlace('):mobile.index('private func placeRow(')]
assert restore_source.index('scrollAccess.matches(attachment)') < restore_source.index('ChatReadingStore.shared.takeRequest'), "unattached views cannot consume queued reading requests"
assert 'model.viewportContinuity.release(generation: model.selectionGeneration, owner: presenceOwner)' in mobile, "teardown must release only its own lease and preserve the place"
access_source = mobile[mobile.index('private final class ClientTranscriptScrollAccess'):mobile.index('private final class ClientTranscriptReadingFrames')]
assert 'guard !current.isHidden, current.alpha > 0.01' in access_source and 'ChatViewportAttachment.isVisible' in access_source, "attachment must check local ancestor visibility and the local window intersection"
assert 'window.windowScene?.activationState == .foregroundActive' in access_source, "background UIKit attachments cannot claim a foreground reader"
assert 'DispatchQueue.main.async' in access_source and 'let identity = self.liveAttachmentIdentity' in access_source and 'attachment.publish(identity, reporter: reporterID)' in access_source, "attachment publication must be deferred and re-evaluate the live reporter"
assert 'source !== reporter' in access_source and 'self.reporter === reporter' in access_source, "old reporter callbacks and dismantle must not affect a successor"
assert 'model.viewportContinuity.chooseLatest(generation: model.selectionGeneration)' in mobile, "Latest before attachment must retire the old mark without claiming ownership"
capture_source = mobile[mobile.index('private func keepViewport()'):mobile.index('private func captureReadingAfterQuiet()')]
assert 'scenePhase == .active' in capture_source and 'scrollAccess.matches(attachment)' in capture_source, "direct Latest samples must also require the live foreground attachment"
assert 'ChatViewportAttachment.isCurrentPresentation(visible: visible' in mobile, "obsolete folder wrappers cannot acquire a lease"
recent = (root / "apps/mac/Sources/Client/ClientRecentChats.swift").read_text()
assert 'isActive: ChatViewportAttachment.isCurrentPresentation(visible: visible' in recent, "obsolete recent wrappers cannot acquire a lease"
assert 'rootCover: rootChatReference, currentCover: navigation.presentedChat?.reference' in recent, "stable root covers must validate the immutable current cover instead of underlying layout generation"
assert 'scrollAccess.refreshAttachment(retryVisibility: true)' in mobile, "foreground and appearance changes must refresh actual attachment"
assert 'if retryVisibility || readinessSource != sourceIdentity { cancelReadiness() }' in access_source, "a changed attachment or explicit retry must cancel an older readiness task before restarting"
assert 'for _ in 0..<12' in access_source and 'attachment.beginReadiness(identity)' in access_source and 'attachment.takeReadinessAttempt(identity, ticket: ticket)' in access_source, "fade readiness must use a bounded episode that layout frames cannot replenish"
assert 'self.sourceIdentity == identity' in access_source and 'self.readinessTaskID == ticket' in access_source, "deferred visibility probes must belong to their actual reporter/scroll/window and task"
assert 'if liveAttachmentIdentity != nil {\n            cancelReadiness()\n            attachment.resetReadiness()' in access_source, "observed eligibility must end an old probe so a subsequent same-source fade can receive its own episode"
assert 'self?.attachment.finishReadiness(ticket: ticket) == true' in access_source, "stale probe cleanup cannot clear a newer episode"
opening = mobile[mobile.index("private func loadChat() async {"):mobile.index("private func updateLiveActivity() async {")]
assert opening.index("guard !Task.isCancelled, isActive else { return }") < opening.index("navigation.takeSuggestedPrompt"), "hidden or cancelled readers must not consume an offered draft"
assert "if let session { await session.select(chat) }" in opening, "layout replacements must share the retained reader's opening"
model = (root / "apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift").read_text()
selection = model[model.index("private func select(_ chat: ChatConversation?"):model.index("rememberRecentMessages()", model.index("private func select(_ chat: ChatConversation?"))]
assert "chat.id == selected?.id" in selection and "!events.isEmpty" not in selection, "an empty same-chat opening must refresh without changing selection generation"
client_root = (root / "apps/mac/Sources/Client/ClientRootView.swift").read_text()
assert "navigation.chatHandoff.pending" in client_root and "navigation.chatHandoff.isCurrent" in client_root, "folding must validate the retained source reader"
assert "intent == navigation.chatHandoff.intent" in client_root and "layoutTicket == navigation.layoutGeneration" in client_root, "late layout delivery must reject explicit navigation and obsolete layout owners"
assert client_root.count(".id(navigation.stackGeneration)") == 2, "both incoming layout subtrees must initialize presentation state after the stack epoch is established"
handoff_source = (root / "apps/mac/Sources/Client/ClientChatLayoutHandoff.swift").read_text()
link = handoff_source[handoff_source.index("struct ClientOwnedNavigationLink"):handoff_source.index("struct ClientOwnedPushDestination")]
assert "navigationDestination" not in link and "navigation.pushOwned(ClientOwnedPush" in link, "lazy tiles and removable pins must not own destination registration"
assert client_root.count(".modifier(ClientOwnedPushDestination(tab: tab))") == 2, "both tab implementations need stable root destination registration"
sidebar = (root / "apps/mac/Sources/Client/ClientSidebarRoot.swift").read_text()
assert ".modifier(ClientOwnedPushDestination(tab: navigation.destination))" in sidebar, "sidebar pushes must use their stable detail root"
requested = mobile[mobile.index("private func openRequestedChat() async"):mobile.index("/// The slim strip both chat screens")]
assert "request == navigation.requestedChatGeneration" in requested and "reader.selected?.id == id" in requested, "requested chat publication must reject superseded requests and selections"
chat_menu = (root / "apps/mac/Sources/Client/ClientChatMenu.swift").read_text()
fork_action = chat_menu[chat_menu.index('let ticket = navigation.chatActionTicket()'):chat_menu.index('}.disabled(copying')]
assert fork_action.index('let ticket =') < fork_action.index('Task {'), "Fork must capture navigation ownership before launching its task"
assert "navigation.acceptsChatAction(ticket)" in fork_action and "visible && !Task.isCancelled" in fork_action, "Fork delivery must validate intent, stack, account and visibility"
assert fork_action.index('guard isCurrent() else') > fork_action.index('func isCurrent()'), "Fork must guard before its mutation"
assert fork_action.index('guard isCurrent() else', fork_action.index('await model.fork')) < fork_action.index('onFork?(copied)'), "late Fork cannot navigate after its source leaves"
terminal_screen = (root / "apps/mac/Sources/Client/ClientTerminalSession.swift").read_text()
terminal_teardown = terminal_screen[terminal_screen.index('// Full-screen dismiss:'):terminal_screen.index('.confirmationDialog(', terminal_screen.index('// Full-screen dismiss:'))]
assert 'navigation.leaveTerminal(owner: session.id)' in terminal_teardown and 'scenePhase ==' not in terminal_teardown, "owned terminal teardown must retire its route even while inactive"
terminal_presentation = (root / "apps/mac/Sources/Client/ClientTerminalPresentation.swift").read_text()
assert '.onChange(of: model.activeTerminal?.id)' in terminal_presentation and 'navigation.leaveTerminal(owner: previous)' in terminal_presentation, "authoritative terminal dismissal must clear its owned route"
assert "opened = chat\n        publishChat(id)" in requested, "unchanged opened identifiers still need explicit guarded publication"

# Focused chrome must not subtract width from the mode/permission row. This
# source gate complements native checks of actual SwiftUI intrinsic sizing.
composer = (root / "apps/mac/Sources/Client/ClientChatComposer.swift").read_text()
setup = (root / "apps/mac/Sources/Features/Workspaces/Chat/ChatSetupHeader.swift").read_text()
compact = setup[setup.index("private var compactLayout:"):setup.index("private var content:")]
agent_row, pill_rows = compact.split("ViewThatFits(in: .horizontal)", 1)
assert "agentField" in agent_row and "chrome" in agent_row and "pills(" not in agent_row, "focus/running chrome must share only the flexible agent row"
assert "chrome" not in pill_rows and pill_rows.count("pills(fitsWidth: true)") == 2, "both horizontal and stacked pill candidates must receive the whole row width"
assert "VStack(alignment: .leading, spacing: Theme.Space.s)" in pill_rows, "narrow or large-text controls need a stacked fallback"
pills = setup[setup.index("struct ChatCompactPills:"):setup.index("/// Capture before scheduling")]
assert "var fitsWidth = false" in pills and ".fixedSize(horizontal: !fitsWidth, vertical: true)" in pills, "mobile groups must permit label wrapping while preserving desktop's default intrinsic width"
assert ".frame(maxWidth: fitsWidth ? .infinity : nil, alignment: .leading)" in pills and ".frame(minHeight: 44)" in pills, "wrapping groups must accept their local width and preserve touch targets"
field = composer[composer.index("private var field:"):composer.index("private func hideKeyboard()")]
assert ".frame(minWidth: 0, maxWidth: .infinity," in field, "the writing field must shrink to its local offered width"
assert ".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)" in composer, "the composer must accept the containing chat's width"
assert "extension ChatComposerControls where Chrome == EmptyView" in setup, "desktop callers must retain a chrome-free default"
