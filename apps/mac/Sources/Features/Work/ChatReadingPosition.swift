// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CoreGraphics

enum ChatReadingPosition: Equatable {
    case latest
    case away(ChatReadingMark)
    case unknown

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

    static func from(atEnd: Bool, pinned: Bool, anchorID: String?, anchorTop: Double,
                      anchorHeight: Double, viewportHeight: Double,
                      at date: Date = Date()) -> Self {
        if atEnd, pinned { return .latest }
        guard viewportHeight > 0, let anchorID else { return .unknown }
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

struct ChatReadingIdentity: Hashable {
    let reference: WorkReference?
    let generation: UInt64
    var restoration: UInt64 = 0
}

struct ChatPresentationIdentity: Hashable {
    let reading: ChatReadingIdentity
    let active: Bool
}
