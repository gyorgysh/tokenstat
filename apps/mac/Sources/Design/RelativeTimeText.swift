// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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

    private(set) var now = Date()

    private static let tick: Duration = .seconds(15)

    @ObservationIgnored fileprivate var wasRead = false

    private init() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                guard self.wasRead else { continue }
                self.wasRead = false
                self.now = Date()
            }
        }
    }
}

extension RelativeClock {
    static func phrase(
        for date: Date,
        style: RelativeDateTimeFormatter.UnitsStyle = .full
    ) -> String {
        // Two different jobs, deliberately separated. Reading `now` is the
        // subscription: it is what makes SwiftUI call this body again on the
        // next tick, and it is the only reason the property exists. The words
        // are measured against the real current time, so a clock that went
        // dormant because nothing was on screen cannot make the first phrase
        // after that read hours late. `max` keeps the read load-bearing so
        // nobody deletes it as unused.
        let ticked = shared.now
        shared.wasRead = true
        let now = max(ticked, Date())
        if abs(date.timeIntervalSince(now)) < 60 { return L10n.text("apple.relativetimetext.just_now.7ddb44d8") }
        formatter.unitsStyle = style
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static let formatter = RelativeDateTimeFormatter()
}

struct RelativeTimeText: View {
    let date: Date
    var unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .full

    var body: some View {
        Text(RelativeClock.phrase(for: date, style: unitsStyle))
    }
}
