// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatReadingStore.swift ChatReadingPosition.swift
// TranscriptReading.swift ChatReadingAnchor.swift.
import SwiftUI

@MainActor final class ChatModel {
    var selectionGeneration: UInt64 = 0
    var currentReference: WorkReference?
    var openingConversation = false
    var displayItems: [Row] = [ChatModel.Row(id: "text-s1")]
    struct Row { let id: String; var lastSequence: UInt64? = nil }
    var events: [ChatTimelineEvent] = []
    var hasEarlier = false
    var reachedStart = false
    /// Pages the next fetch reveals, oldest first. Empty means the host
    /// answers with nothing further.
    var earlierPages: [[Row]] = []
    var fetches = 0
    func loadEarlier() async {
        fetches += 1
        guard !earlierPages.isEmpty else {
            hasEarlier = false
            reachedStart = true
            return
        }
        displayItems = earlierPages.removeFirst() + displayItems
        if earlierPages.isEmpty {
            hasEarlier = false
            reachedStart = true
        }
    }
}
typealias ChatDisplayItem = ChatModel.Row
struct ChatTimelineEvent {
    var seq: UInt64?
    var event: Event?
    struct Event { var kind: String }
}
@MainActor final class TranscriptFollowState {
    var atEnd = false
    var pinned = false
    var abandoned = false
    var settling = false
    var stops = 0
    func settle(_ value: Bool) { settling = value }
    func stopFollowing() { stops += 1 }
}
@MainActor final class TranscriptWindow {
    var anchor: Anchor?
    var viewportHeight: CGFloat = 800
    struct Anchor { let id: String; let top: CGFloat; let height: CGFloat = 44 }
}

@main struct TranscriptReadingTests {
    @MainActor static func main() async {
        let reference = WorkReference(scope: .local(installationID: "local"),
            hostIdentity: "host", workspaceID: "folder", kind: .conversation, itemID: "chat")
        let mark = ChatReadingMark(eventID: "text-s1", offset: 0, updatedAt: Date())
        let model = ChatModel()
        model.currentReference = reference
        let follow = TranscriptFollowState()
        var placements = 0
        let restored = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { _, _ in placements += 1 }
        assert(restored == .restored && placements == 4 && follow.stops == 1)
        assert(!follow.settling)

        // Navigation during the first placement cannot move the next chat or
        // end the next chat's own settling task, even when row IDs repeat.
        placements = 0
        let switched = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { _, _ in
                placements += 1
                model.selectionGeneration += 1
            }
        assert(switched == .interrupted && placements == 1)
        assert(follow.settling && follow.stops == 1)

        // Losing the account scope interrupts before another row is placed.
        placements = 0
        let signedOut = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { _, _ in
                placements += 1
                model.currentReference = nil
            }
        assert(signedOut == .interrupted && placements == 1)
        model.currentReference = reference

        // A person scrolling takes ownership from restoration.
        follow.abandoned = true
        let scrolled = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { _, _ in assertionFailure("Moved during scrolling") }
        assert(scrolled == .interrupted && !follow.settling)
        follow.abandoned = false

        let cancelled = Task { @MainActor in
            await TranscriptReading.restore(mark, reference: reference,
                model: model, follow: follow) { _, _ in assertionFailure("Moved after cancellation") }
        }
        cancelled.cancel()
        let cancellation = await cancelled.value
        assert(cancellation == .interrupted)

        var running: Task<TranscriptReading.Restoration, Never>?
        placements = 0
        running = Task { @MainActor in
            await TranscriptReading.restore(mark, reference: reference,
                model: model, follow: follow) { _, _ in
                    placements += 1
                    running?.cancel()
                }
        }
        let interrupted = await running!.value
        assert(interrupted == .interrupted && placements == 1 && !follow.settling)

        model.displayItems = []
        let missing = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { _, _ in assertionFailure("Placed missing row") }
        assert(missing == .unavailable && !follow.settling)

        // A row above the loaded page is screens away, not gone: restoration
        // pulls older pages until it appears, then lands on it.
        model.displayItems = [ChatModel.Row(id: "text-s9")]
        model.hasEarlier = true
        model.earlierPages = [[ChatModel.Row(id: "text-s1")]]
        var landed: UnitPoint?
        let paged = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { id, point in
                assert(id == "text-s1")
                landed = point
                placements += 1
            }
        assert(paged == .restored && model.fetches == 1 && !follow.settling)
        assert(landed == UnitPoint(x: 0.5, y: 0))

        // Inside a long row the placement carries the reader's fraction
        // down it rather than the row's top edge in the viewport.
        let deep = ChatReadingMark(eventID: "text-s1", offset: 0,
                                   updatedAt: Date(), within: 0.5)
        var deepPoint: UnitPoint?
        let deepRestored = await TranscriptReading.restore(deep, reference: reference,
            model: model, follow: follow) { _, point in deepPoint = point }
        assert(deepRestored == .restored && deepPoint == UnitPoint(x: 0.5, y: 0.5))

        // Pages that never contain the row end at the start of the chat,
        // and the conversation opens at its latest turn instead of waiting.
        model.displayItems = [ChatModel.Row(id: "text-s9")]
        model.hasEarlier = true
        model.reachedStart = false
        model.earlierPages = [[ChatModel.Row(id: "text-s8")]]
        let gone = await TranscriptReading.restore(mark, reference: reference,
            model: model, follow: follow) { _, _ in assertionFailure("Placed missing row") }
        assert(gone == .unavailable && model.fetches == 2 && !follow.settling)

        print("Transcript reading: restoration, navigation, scope changes, scrolling, cancellation, missing rows, earlier pages and within-row places passed")
    }
}
