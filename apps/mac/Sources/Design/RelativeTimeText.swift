// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation
import SwiftUI

/// One clock for every "3 minutes ago" in the app.
///
/// # Why this exists
///
/// `Text(date, style: .relative)` and `Text(date, format: .relative(...))` look
/// like the free way to keep an age current: SwiftUI updates them by itself and
/// no screen has to own a timer. What they actually install is a live time
/// source in the view graph, and SwiftUI re-resolves it **on every display
/// cycle**, whether or not the words changed.
///
/// The cost is not the resolve. It is that a dirty attribute forces
/// `NSHostingView.layout()`, which forces `-[NSWindow _layoutViewTree]`, which
/// walks the window's whole `NSView` subtree, every frame, forever. Measured on
/// a running app with four sessions and 8 KB/s of terminal output: the main
/// thread was busy 49% of the time, 1100 of 1395 busy samples were inside
/// `CA::Context::commit_transaction`, and 357 of those were that layout walk.
/// Terminal parsing over the same window was five samples. The app was spending
/// half its main thread re-laying out a window so that "2 minutes ago" could be
/// recomputed sixty times a second and come out the same.
///
/// It got worse with rows on screen rather than with output, which is why it
/// read as unrelated to what the agents were doing: one live source per idle
/// session in the sidebar, one per commit row, one per quota window.
///
/// # What this does instead
///
/// One tick for the whole app, at a granularity the words actually have. Named
/// relative text changes at minute boundaries, so a quarter-minute tick is
/// already finer than anything a reader can see, and it costs one view graph
/// update every fifteen seconds instead of one per frame per row.
@MainActor
@Observable
final class RelativeClock {
    static let shared = RelativeClock()

    /// Read this inside a `body` to be re-evaluated on the tick. Reading it is
    /// the subscription, so a view that formats against it stays current.
    private(set) var now = Date()

    /// Coarse on purpose. See the type's note: the phrasing this drives moves
    /// at minute boundaries, and anything finer buys nothing but wake-ups.
    private static let tick: Duration = .seconds(15)

    private init() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                self.now = Date()
            }
        }
    }
}

extension RelativeClock {
    /// "3 minutes ago", or "in 2 hours", current to within a tick.
    ///
    /// **Call this from inside a `body`.** Reading `shared.now` is what
    /// subscribes the view to the tick, so a phrase built anywhere else is a
    /// snapshot that never updates. That is the one rule this type has, and it
    /// is the same rule `Text(_, style: .relative)` hides from you at the cost
    /// of a layout pass per frame.
    static func phrase(
        for date: Date,
        style: RelativeDateTimeFormatter.UnitsStyle = .full
    ) -> String {
        let reference = shared.now
        formatter.unitsStyle = style
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// Shared because building one is not free and this renders once per row.
    /// MainActor-isolated with the rest of this file, which is what makes a
    /// single mutable formatter safe here.
    private static let formatter = RelativeDateTimeFormatter()
}

/// "3 minutes ago", current to within a tick, without a per-row live clock.
///
/// A drop-in for `Text(date, format: .relative(presentation:))`. Where the
/// phrase has to sit inside a larger sentence, use `RelativeClock.phrase`
/// directly rather than reaching for the live formatter again.
struct RelativeTimeText: View {
    let date: Date
    var presentation: RelativeDateTimeFormatter.UnitsStyle = .full

    var body: some View {
        Text(RelativeClock.phrase(for: date, style: presentation))
    }
}
