// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

@MainActor
enum TranscriptReading {
    enum Restoration { case restored, unavailable, unmeasured, interrupted }
    enum MeasuredPlacement { case placed, settled, unavailable, interrupted }

    static func position(follow: TranscriptFollowState, window: TranscriptWindow,
                         includingContainingRow: Bool = false) -> ChatReadingPosition {
        let anchor = includingContainingRow
            ? ChatReadingPosition.anchor(in: window.rowFrames, viewportHeight: Double(window.viewportHeight))
            : window.anchor.map { (id: $0.id, top: Double($0.top), height: Double($0.height)) }
        return ChatReadingPosition.from(atEnd: follow.atEnd, pinned: follow.pinned,
            anchorID: anchor?.id, anchorTop: anchor?.top ?? 0,
            anchorHeight: anchor?.height ?? 0,
            viewportHeight: Double(window.viewportHeight))
    }

    static func record(follow: TranscriptFollowState, window: TranscriptWindow,
                       for reference: WorkReference?,
                       includingContainingRow: Bool = false,
                       into suppliedStore: ChatReadingStore? = nil) {
        record(position(follow: follow, window: window, includingContainingRow: includingContainingRow),
               for: reference, into: suppliedStore)
    }

    static func record(_ position: ChatReadingPosition, for reference: WorkReference?,
                       into suppliedStore: ChatReadingStore? = nil) {
        guard let reference else { return }
        let store = suppliedStore ?? .shared
        switch position {
        case .latest: store.forget(for: reference)
        case let .away(mark): store.remember(mark, for: reference)
        case .unknown: break
        }
    }

    private static let frames = 40
    private static let frame: Duration = .milliseconds(50)
    private static let corrections = 3
    private static let earlierPages = 8

    static func restore(_ mark: ChatReadingMark, reference: WorkReference, model: ChatModel,
                        follow: TranscriptFollowState,
                        isCurrent: () -> Bool = { true },
                        correct: ((String, ChatReadingMark) -> MeasuredPlacement)? = nil,
                        place: (String, UnitPoint) -> Void) async -> Restoration {
        let generation = model.selectionGeneration
        guard !Task.isCancelled, isCurrent(), model.currentReference == reference else { return .interrupted }
        let point: UnitPoint
        if mark.within > 0 {
            point = UnitPoint(x: 0.5, y: correct == nil ? min(max(mark.within, 0), 0.9) : 0)
        } else {
            point = UnitPoint(x: 0.5, y: min(max(mark.offset, 0), 0.6))
        }
        let wasPinned = follow.pinned
        follow.settle(true)
        follow.pinned = false
        var placements = 0
        var measurements = 0
        var fetched = 0
        for _ in 0..<frames {
            try? await Task.sleep(for: frame)
            guard model.currentReference == reference,
                  model.selectionGeneration == generation, isCurrent() else { return .interrupted }
            if Task.isCancelled {
                follow.settle(false)
                return .interrupted
            }
            if follow.abandoned {
                follow.settle(false)
                follow.stopFollowing()
                return .interrupted
            }
            if model.openingConversation, placements == 0, fetched == 0 { continue }
            guard let rowID = ChatReadingAnchor.resolve(mark.eventID, items: model.displayItems, events: model.events) else {
                guard fetched < earlierPages, model.hasEarlier, !model.reachedStart else { break }
                await model.loadEarlier()
                fetched += 1
                continue
            }
            let visibleRow = mark.revealTarget ? model.revealRow(rowID) : model.readingRow(rowID)
            let correction = placements > 0 ? correct?(visibleRow, mark) : nil
            switch correction {
            case .placed: measurements += 1
            case .settled:
                follow.settle(false)
                follow.stopFollowing()
                return .restored
            case .interrupted:
                follow.settle(false)
                follow.stopFollowing()
                return .interrupted
            case .unavailable: continue
            case nil: place(visibleRow, point)
            }
            placements += 1
            if placements > corrections { break }
        }
        follow.settle(false)
        guard placements > 0 else {
            follow.pinned = wasPinned
            return .unavailable
        }
        follow.stopFollowing()
        if correct != nil, measurements == 0 { return .unmeasured }
        return .restored
    }
}
