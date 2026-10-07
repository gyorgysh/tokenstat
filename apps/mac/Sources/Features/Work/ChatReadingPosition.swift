// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreGraphics

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

    /// Reading can be inside a tall message. Paging's insertion anchor has
    /// different rules, so keep that anchor independent of this measurement.
    static func anchor(in frames: [String: CGRect], viewportHeight: Double,
                       viewportTop: Double = 0, frameOffsetY: Double = 0)
        -> (id: String, top: Double, height: Double)? {
        guard viewportHeight.isFinite, viewportHeight > 0,
              viewportTop.isFinite, frameOffsetY.isFinite else { return nil }
        let visible = frames.filter { $0.value.height > 0
            && Double($0.value.maxY) + frameOffsetY > viewportTop
            && Double($0.value.minY) + frameOffsetY < viewportTop + viewportHeight }
        let containing = visible.filter { Double($0.value.minY) + frameOffsetY <= viewportTop }
            .max { $0.value.minY < $1.value.minY }
        guard let picked = containing ?? visible.min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        return (picked.key, Double(picked.value.minY) + frameOffsetY - viewportTop,
                Double(picked.value.height))
    }

    static func correction(for mark: ChatReadingMark, rowTop: Double,
                           rowHeight: Double, viewportHeight: Double) -> Double? {
        guard rowTop.isFinite, rowHeight.isFinite, viewportHeight.isFinite,
              rowHeight > 0, viewportHeight > 0 else { return nil }
        let desired = mark.within > 0 ? -min(max(mark.within, 0), 1) * rowHeight
            : min(max(mark.offset, 0), 0.6) * viewportHeight
        return rowTop - desired
    }

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
        guard viewportHeight > 0, let anchorID else { return .unknown }
        // A folded header stands for its first archive row. Persist that
        // row's existing identifier so older versions can read the mark too.
        let eventID = anchorID.hasPrefix("g:") ? String(anchorID.dropFirst(2)) : anchorID
        guard ChatReadingMark.isStable(eventID: eventID) else { return .unknown }
        if anchorTop < 0, anchorHeight > 0 {
            return .away(
                ChatReadingMark(eventID: eventID, offset: 0,
                                updatedAt: date,
                                within: min(max(-anchorTop / anchorHeight, 0), 1))
            )
        }
        return .away(
            ChatReadingMark(eventID: eventID,
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

/// Retained desktop panes must settle again when they become visible.
struct ChatPresentationIdentity: Hashable {
    let reading: ChatReadingIdentity
    let active: Bool
}
