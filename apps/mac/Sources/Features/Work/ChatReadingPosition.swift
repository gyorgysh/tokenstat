// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// What a transcript's geometry says about where the reading is.
///
/// The end of a conversation is not a place: it is where a conversation opens
/// anyway, and it moves every time the agent says something. So being at the
/// end is kept as no record at all, and a record means "open this one
/// somewhere other than the latest turn".
enum ChatReadingPosition: Equatable {
    /// With the latest turn. Nothing to keep.
    case latest
    /// Above it, on this row.
    case away(ChatReadingMark)
    /// The rows have not said where they are, so this frame knows nothing.
    /// Whatever was kept before is still the best answer.
    case unknown

    /// `top` is the row's top edge measured from the top of the viewport, in
    /// the same points `viewportHeight` is in. The mark keeps their ratio,
    /// because the same conversation is a different height on a phone, at a
    /// larger text size, or with an older page loaded above it. `height` is
    /// the row's own height in the same points: when the top has scrolled
    /// past the viewport's edge the reader is inside the row, and the mark
    /// keeps how far down it as a fraction of that height. A reader halfway
    /// down a long message reopens in its middle, not at its first line.
    static func from(atEnd: Bool, pinned: Bool, anchorID: String?, anchorTop: Double,
                      anchorHeight: Double, viewportHeight: Double,
                      at date: Date = Date()) -> Self {
        if atEnd, pinned { return .latest }
        guard viewportHeight > 0, let anchorID,
              ChatReadingMark.isStable(eventID: anchorID) else { return .unknown }
        if anchorTop < 0, anchorHeight > 0 {
            return .away(
                ChatReadingMark(eventID: anchorID, offset: 0,
                                updatedAt: date,
                                within: min(max(-anchorTop / anchorHeight, 0), 1))
            )
        }
        return .away(
            ChatReadingMark(eventID: anchorID,
                            offset: min(max(anchorTop / viewportHeight, 0), 1),
                            updatedAt: date)
        )
    }
}

/// A transcript task belongs to this selection, even while account identity
/// is still loading or the same conversation is reopened after a refresh.
struct ChatReadingIdentity: Hashable {
    let reference: WorkReference?
    let generation: UInt64
    var restoration: UInt64 = 0
}
