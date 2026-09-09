// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift ChatReadingStore.swift ChatReadingPosition.swift
// TranscriptReading.swift.
import SwiftUI

@MainActor final class ChatModel {
    var selectionGeneration: UInt64 = 0
    var currentReference: WorkReference?
    var openingConversation = false
    var displayItems: [Row] = [Row(id: "text-s1")]
    struct Row { let id: String }
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
    struct Anchor { let id: String; let top: CGFloat }
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
        print("Transcript reading: restoration, navigation, scope changes, scrolling, cancellation and missing rows passed")
    }
}
