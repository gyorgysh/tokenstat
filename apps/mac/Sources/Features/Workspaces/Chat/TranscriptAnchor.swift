// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A row and where it was, so it can be put back after rows arrive above it.
///
/// A lazy stack keeps its offset when rows are inserted above the viewport,
/// so what is on screen moves down by everything inserted. Nothing in
/// SwiftUI holds it still on macOS or iOS: not the content offset
/// adjustment, not a bottom anchor for size changes, not a bound scroll
/// position id. Each was measured against a resting viewport and each left
/// the reader's row hundreds of points away. A `scrollTo` with this row and
/// `unitPoint` is what puts it back exactly.
struct TranscriptAnchor: Equatable {
    let id: String
    /// Its top edge, measured from the top of the viewport. Negative when the
    /// row starts above the viewport, which is where a reader inside a long
    /// reply always is.
    let top: CGFloat
    let height: CGFloat

    /// The row to hold: the one covering the viewport's top edge, or the
    /// first one below it.
    ///
    /// The row the reader is looking at, whatever its height. Picking only
    /// rows that start on screen used to skip a reply taller than the window
    /// and anchor on the next row screens below, or on nothing at all, and
    /// a page then landed with nothing holding the place.
    ///
    /// A row exactly as tall as the viewport has no unit point that moves it
    /// (see `unitPoint`), so the next one is used instead.
    static func pick(_ frames: [String: CGRect], viewportHeight: CGFloat) -> TranscriptAnchor? {
        candidates(frames, viewportHeight: viewportHeight).first
    }

    /// The rows on screen that can be held, top first. The second is the
    /// fallback when a page turns the first into a row of another kind.
    static func candidates(_ frames: [String: CGRect], viewportHeight: CGFloat) -> [TranscriptAnchor] {
        guard viewportHeight > 0 else { return [] }
        let rows = frames
            .filter { _, frame in
                frame.height >= 1 && frame.maxY > 1 && frame.minY < viewportHeight
                    && abs(viewportHeight - frame.height) >= 1
            }
            .sorted { lhs, rhs in
                lhs.value.minY == rhs.value.minY ? lhs.key < rhs.key : lhs.value.minY < rhs.value.minY
            }
        return rows.map { TranscriptAnchor(id: $0.key, top: $0.value.minY, height: $0.value.height) }
    }

    /// The unit point that puts this row's top back at `top`.
    ///
    /// `scrollTo(_:anchor:)` lines the item's point at fraction `t` up with
    /// the container's point at the same fraction. With an item of height `h`
    /// in a viewport of height `v`, the item's top lands at `t * (v - h)`, so
    /// `t = top / (v - h)`.
    ///
    /// Not clamped to 0...1. A row taller than the viewport, or one that
    /// starts above it, needs a fraction outside that range, and SwiftUI
    /// honours it. Clamping is what turned a reader halfway into a long reply
    /// into a reader at its bottom edge.
    func unitPoint(in viewportHeight: CGFloat) -> UnitPoint {
        let room = viewportHeight - height
        guard abs(room) >= 1 else { return UnitPoint(x: 0, y: 0) }
        return UnitPoint(x: 0, y: top / room)
    }

    /// How far the row now is from where it was.
    func drift(to frame: CGRect) -> CGFloat {
        frame.minY - top
    }
}
