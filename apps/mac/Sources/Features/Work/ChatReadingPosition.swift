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
    /// larger text size, or with an older page loaded above it.
    static func from(atEnd: Bool, pinned: Bool, anchorID: String?, anchorTop: Double,
                     viewportHeight: Double, at date: Date = Date()) -> Self {
        if atEnd, pinned { return .latest }
        guard viewportHeight > 0, let anchorID,
              ChatReadingMark.isStable(eventID: anchorID) else { return .unknown }
        return .away(
            ChatReadingMark(eventID: anchorID,
                            offset: min(max(anchorTop / viewportHeight, 0), 1),
                            updatedAt: date)
        )
    }
}
