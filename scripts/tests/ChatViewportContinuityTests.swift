// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatViewportContinuity.swift ChatReadingPosition.swift ChatReadingStore.swift WorkReference.swift.
import Foundation
import CoreGraphics

@main
struct ChatViewportContinuityTests {
    @MainActor static func main() {
        let viewport = ChatViewportContinuity()
        let mark = ChatReadingMark(eventID: "text-s12", offset: 0.2, updatedAt: Date(), within: 0.4)
        var owner = UUID()
        precondition(viewport.claim(generation: 1, owner: owner) == nil)
        viewport.record(.away(mark), generation: 1, owner: owner)
        for _ in 0..<30 {
            let next = UUID()
            precondition(viewport.claim(generation: 1, owner: next) == mark)
            // The outgoing layout can disappear after its successor claims.
            viewport.record(.latest, generation: 1, owner: owner)
            precondition(viewport.mark(generation: 1) == mark)
            viewport.record(.unknown, generation: 1, owner: next)
            precondition(viewport.mark(generation: 1) == mark)
            owner = next
        }
        viewport.record(.latest, generation: 1, owner: owner)
        // Explicit Jump/Send intent wins even before the scroll chase settles.
        precondition(viewport.claim(generation: 1, owner: UUID()) == nil)
        owner = UUID()
        viewport.claim(generation: 1, owner: owner)
        precondition(viewport.mark(generation: 1) == nil)
        viewport.record(.away(mark), generation: 1, owner: owner)
        let requested = ChatReadingMark(eventID: "text-s99", offset: 0, updatedAt: Date())
        viewport.record(.away(requested), generation: 1, owner: owner)
        let replacement = UUID()
        precondition(viewport.claim(generation: 1, owner: replacement) == requested,
            "explicit reading intent must survive remount before first placement")
        viewport.record(.away(mark), generation: 1, owner: owner)
        precondition(viewport.mark(generation: 1) == requested)
        owner = replacement
        precondition(viewport.claim(generation: 2, owner: owner) == nil)
        viewport.record(.away(mark), generation: 1, owner: owner)
        precondition(viewport.mark(generation: 2) == nil)
        precondition(viewport.mark(generation: 1) == nil)
        let anotherReader = ChatViewportContinuity()
        precondition(anotherReader.claim(generation: 1, owner: UUID()) == nil)
        let intermediate = UUID()
        viewport.beginPlacement(generation: 2, owner: owner)
        viewport.record(.away(mark), generation: 2, owner: owner)
        viewport.completePlacement(generation: 2, owner: owner)
        // Teardown can precede the new owner's claim and report the bottom.
        viewport.recordMeasurement(.latest, generation: 2, owner: owner, readerInitiated: false)
        precondition(viewport.mark(generation: 2) == mark)
        viewport.recordMeasurement(.away(requested), generation: 2, owner: owner, readerInitiated: false)
        precondition(viewport.mark(generation: 2) == mark, "Resize/teardown away geometry replaced the settled reading mark")
        viewport.beginPlacement(generation: 2, owner: intermediate)
        precondition(!viewport.isPlaced(generation: 2, owner: owner))
        precondition(!viewport.isPlaced(generation: 2, owner: intermediate))
        // This presentation is cancelled before a row is placed.
        viewport.recordMeasurement(.away(requested), generation: 2, owner: intermediate, readerInitiated: true)
        viewport.recordMeasurement(.latest, generation: 2, owner: intermediate, readerInitiated: true)
        precondition(viewport.mark(generation: 2) == mark)
        let settled = UUID()
        precondition(viewport.beginPlacement(generation: 2, owner: settled) == mark)
        viewport.completePlacement(generation: 2, owner: intermediate)
        viewport.recordMeasurement(.away(requested), generation: 2, owner: settled, readerInitiated: true)
        precondition(viewport.mark(generation: 2) == mark, "Late completion enabled a successor's initial geometry")
        viewport.completePlacement(generation: 2, owner: settled)
        precondition(viewport.isPlaced(generation: 2, owner: settled))
        viewport.recordMeasurement(.away(requested), generation: 2, owner: settled, readerInitiated: true)
        precondition(viewport.mark(generation: 2) == requested)
        // A moving reporter and row must be captured in the same pass. A
        // paired old snapshot can translate to today's native position;
        // fresh rows with an old reporter would count the movement twice.
        let previousGlobalTop = 500.0
        let freshGlobalTop = 400.0
        let nativeReporterTop = 448.0
        let paired = ChatReadingPosition.anchor(in: ["text-s2": CGRect(x: 0, y: 100, width: 300, height: 100)],
            viewportHeight: 306, viewportTop: 135, frameOffsetY: nativeReporterTop - freshGlobalTop)!
        precondition(paired.top == 13)
        let pairedPrevious = ChatReadingPosition.anchor(in: ["text-s2": CGRect(x: 0, y: 200, width: 300, height: 100)],
            viewportHeight: 306, viewportTop: 135, frameOffsetY: nativeReporterTop - previousGlobalTop)!
        precondition(pairedPrevious.top == paired.top)
        let hold = ChatReadingHold()
        let closedViewport = CGRect(x: 0, y: 82, width: 466, height: 312.667)
        let openViewport = CGRect(x: 312, y: 135, width: 543, height: 306)
        hold.prepare(mark: mark, viewport: closedViewport)
        precondition(hold.canCorrect && hold.takeReveal())
        precondition(!hold.takeReveal(), "Unchanged geometry must not repeatedly reveal a missing row")
        for _ in 0..<6 {
            precondition(hold.canCorrect)
            hold.corrected()
            hold.prepare(mark: mark, viewport: closedViewport)
        }
        precondition(!hold.canCorrect, "Lazy-height corrections must have a finite budget")
        hold.prepare(mark: mark, viewport: closedViewport.offsetBy(dx: 0, dy: 0.1))
        precondition(!hold.canCorrect, "Fractional coordinate noise must not replenish the correction budget")
        hold.prepare(mark: mark, viewport: openViewport)
        precondition(hold.canCorrect && hold.takeReveal(), "A changed usable viewport earns one fresh reveal")
        hold.reset()
        precondition(!hold.canCorrect && !hold.takeReveal(), "Reader input or latest must retire queued correction permission")
        hold.prepare(mark: requested, viewport: openViewport)
        precondition(hold.canCorrect && hold.takeReveal(), "A new reading intent starts a fresh hold episode")
        viewport.recordMeasurement(.away(mark), generation: 2, owner: settled, readerInitiated: false)
        precondition(viewport.mark(generation: 2) == requested, "Programmatic placement completion changed reading intent")
        viewport.record(.latest, generation: 2, owner: settled)
        precondition(viewport.mark(generation: 2) == nil)
        viewport.recordMeasurement(.away(mark), generation: 2, owner: settled, readerInitiated: false)
        precondition(viewport.mark(generation: 2) == nil, "A resize after Jump restored old reading geometry")
        viewport.recordMeasurement(.away(mark), generation: 2, owner: settled, readerInitiated: true)
        precondition(viewport.mark(generation: 2) == mark, "A new reader gesture must still leave latest")
        let frames = ["text-s1": CGRect(x: 0, y: -200, width: 320, height: 600),
                      "text-s2": CGRect(x: 0, y: 420, width: 320, height: 100),
                      "text-s3": CGRect(x: 0, y: 900, width: 320, height: 100)]
        let inside = ChatReadingPosition.anchor(in: frames, viewportHeight: 700)
        precondition(inside?.id == "text-s1" && inside?.top == -200 && inside?.height == 600)
        let after = ChatReadingPosition.anchor(in: ["text-s2": frames["text-s2"]!], viewportHeight: 700)
        precondition(after?.id == "text-s2")
        precondition(ChatReadingPosition.anchor(in: ["text-s3": frames["text-s3"]!], viewportHeight: 700) == nil)
        precondition(ChatReadingPosition.anchor(in: frames, viewportHeight: 0) == nil)
        for (height, top, within) in [(600.0, -200.0, 1.0 / 3), (1400.0, -700.0, 0.5)] {
            let kept = ChatReadingMark(eventID: "text-s1", offset: 0, updatedAt: Date(), within: within)
            let delta = ChatReadingPosition.correction(for: kept, rowTop: 33, rowHeight: height, viewportHeight: 700)!
            precondition(abs(33 - delta - top) < 0.0001, "Within-row correction changed the kept fraction")
        }
        let offsetMark = ChatReadingMark(eventID: "text-s2", offset: 0.2, updatedAt: Date())
        let offsetDelta = ChatReadingPosition.correction(for: offsetMark, rowTop: 420, rowHeight: 100, viewportHeight: 700)!
        precondition(420 - offsetDelta == 140)
        precondition(ChatReadingPosition.correction(for: mark, rowTop: .infinity, rowHeight: 600, viewportHeight: 700) == nil)
        // Mobile capture and correction share the usable native rectangle,
        // rather than the full scroll bounds. Both bar insets can change.
        let fixedDate = Date(timeIntervalSince1970: 1)
        for (bounds, top, bottom, rootOrigin) in [
            (678.0, 82.0, 283.333333333, 0.0),
            (669.0, 135.0, 228.0, 48.0)
        ] {
            let height = bounds - top - bottom
            let nativeRowTop = top + height * 0.2
            let measured = ["text-s2": CGRect(x: 0, y: nativeRowTop - rootOrigin, width: 300, height: 135),
                            "text-s3": CGRect(x: 0, y: bounds - bottom - rootOrigin, width: 300, height: 100)]
            let anchor = ChatReadingPosition.anchor(in: measured, viewportHeight: height,
                viewportTop: top, frameOffsetY: rootOrigin)!
            precondition(anchor.id == "text-s2" && abs(anchor.top - height * 0.2) < 0.0001)
            let position = ChatReadingPosition.from(atEnd: false, pinned: false,
                anchorID: anchor.id, anchorTop: anchor.top, anchorHeight: anchor.height,
                viewportHeight: height, at: fixedDate)
            guard case let .away(saved) = position else { preconditionFailure("Visible row was not captured") }
            precondition(abs(saved.offset - 0.2) < 0.0001)
            let delta = ChatReadingPosition.correction(for: saved, rowTop: 17, rowHeight: 135,
                viewportHeight: height)!
            precondition(abs(17 - delta - height * 0.2) < 0.0001)
            let clipped = ChatReadingPosition.anchor(in: ["text-s1": CGRect(x: 0,
                y: top - rootOrigin - 200, width: 300, height: 600)],
                viewportHeight: height, viewportTop: top, frameOffsetY: rootOrigin)!
            precondition(clipped.top == -200 && clipped.height == 600)
        }
        // Unknown geometry leaves a settled gesture free to retry; it cannot
        // erase the prior mark while a new preference pass is still arriving.
        viewport.recordMeasurement(.unknown, generation: 2, owner: settled, readerInitiated: true)
        precondition(viewport.mark(generation: 2) == mark)
        viewport.recordMeasurement(.away(requested), generation: 2, owner: settled, readerInitiated: true)
        precondition(viewport.mark(generation: 2) == requested)
        let waitingTicket = UUID()
        viewport.beginPlacement(generation: 2, owner: settled)
        viewport.record(.away(mark), generation: 2, owner: settled)
        precondition(viewport.canPlace(generation: 2, currentGeneration: 2, owner: settled, ticket: waitingTicket, currentTicket: waitingTicket))
        precondition(!viewport.canPlace(generation: 2, currentGeneration: 3, owner: settled, ticket: waitingTicket, currentTicket: waitingTicket),
                     "A same-conversation reopen consumed a new request before continuity caught up")
        let latestTicket = UUID()
        viewport.record(.latest, generation: 2, owner: settled)
        precondition(!viewport.canPlace(generation: 2, currentGeneration: 2, owner: settled, ticket: waitingTicket, currentTicket: latestTicket),
                     "An opening waiter reclaimed explicit latest intent before request consumption")
        let suite = "viewport-opening-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatReadingStore(defaults: defaults)
        let reference = WorkReference(scope: .local(installationID: "viewport-test"),
            hostIdentity: "host", workspaceID: "project", kind: .conversation, itemID: "chat")
        store.request(mark, for: reference)
        _ = store.takeRequest(for: reference)
        precondition(store.takeRequest(for: reference) == nil && store.mark(for: reference) == mark,
                     "A new viewport choice must discard queued navigation without erasing passive history")
        store.request(mark, for: reference)
        store.requestLatest(for: reference)
        precondition(store.takeRequest(for: reference) == nil)
        print("Chat viewport continuity: 30 layout handoffs, late teardown, unknown geometry, latest, new selections and reader isolation passed")
    }
}
