// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Keeping a reader's place in a conversation, and putting them back on it.
///
/// One implementation for both transcripts. A chat on the Mac and the same
/// chat on a phone are the same conversation, and a place kept by one of them
/// is a place the other has to understand. What the geometry means is
/// `ChatReadingPosition`; this is the part that needs a scroll view.
@MainActor
enum TranscriptReading {
    /// Keep, or drop, this conversation's place.
    static func record(follow: TranscriptFollowState, window: TranscriptWindow,
                       for reference: WorkReference?,
                       into store: ChatReadingStore = .shared) {
        guard let reference else { return }
        let anchor = window.anchor
        switch ChatReadingPosition.from(atEnd: follow.atEnd, pinned: follow.pinned,
                                        anchorID: anchor?.id,
                                        anchorTop: anchor.map { Double($0.top) } ?? 0,
                                        viewportHeight: Double(window.viewportHeight)) {
        case .latest: store.forget(for: reference)
        case let .away(mark): store.remember(mark, for: reference)
        case .unknown: break
        }
    }

    /// How long to wait for a conversation's rows before opening it at the
    /// latest turn instead. The same budget the settle onto the end spends.
    private static let frames = 40
    private static let frame: Duration = .milliseconds(50)
    /// Placements after the first. Rows are built at estimated heights and
    /// measured over the frames that follow, so one scroll lands on a stack
    /// that is still settling.
    private static let corrections = 3

    /// Put the viewport back where this conversation was left.
    ///
    /// Answers whether it did. False means the row is no longer in the
    /// conversation, or never arrived, and the caller should open at the
    /// latest turn the way it always has.
    ///
    /// `place` slides the built window so the row is its first, then scrolls
    /// to it. Sliding first is what keeps the walk short: the row ends up at
    /// the top of what is built, so reaching it costs nothing like a walk to
    /// the end of a long conversation would.
    static func restore(_ mark: ChatReadingMark, model: ChatModel,
                        follow: TranscriptFollowState,
                        place: (String, UnitPoint) -> Void) async -> Bool {
        let point = UnitPoint(x: 0, y: min(max(mark.offset, 0), 0.6))
        follow.settle(true)
        var placements = 0
        for _ in 0..<frames {
            try? await Task.sleep(for: frame)
            if Task.isCancelled { break }
            // Still arriving: the row may be in a page that has not landed.
            if model.openingConversation, placements == 0 { continue }
            guard model.displayItems.contains(where: { $0.id == mark.eventID }) else { break }
            place(mark.eventID, point)
            placements += 1
            if placements > corrections { break }
        }
        follow.settle(false)
        guard placements > 0 else { return false }
        // The reader is above the latest turn on purpose, so the transcript
        // stops following it and offers the way back instead of chasing the
        // end under them.
        follow.stopFollowing()
        return true
    }
}
