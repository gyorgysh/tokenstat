// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// What a run's status looks like, in one place.
///
/// Automations and Workflows each carried their own copy of this switch, which
/// is how "stopped" ends up amber on one screen and grey on the next. The two
/// entry points that used to own it now call through here.
enum RunOutcome {
    static func tint(_ status: String) -> Color {
        switch status {
        case "running", "queued": return Theme.stateWorking
        case "waiting": return Theme.warning
        case "ok": return Theme.success
        case "stopped": return Theme.warning
        case "error": return Theme.danger
        case "interrupted": return Theme.warning
        default: return Theme.stateIdle
        }
    }
}

/// The last handful of outcomes as ticks, newest on the right.
///
/// A job whose last three runs failed should look wrong from across the room.
/// Before this, that fact lived in a shared "Recent runs" list at the bottom of
/// the screen, detached from the job it belonged to, so nobody read it as a
/// trend.
struct RunHistoryStrip: View {
    struct Tick: Identifiable {
        var id: String
        var status: String
        var label: String
    }

    /// Oldest first. The view reverses nothing, it just trims the front.
    var ticks: [Tick]
    var limit: Int = 12
    var height: CGFloat = 14
    var width: CGFloat = 4
    var onSelect: ((Tick) -> Void)?

    /// Slots always drawn, so the strip reads as a track that is filling up.
    ///
    /// Two amber ticks on their own are a pause glyph, and next to a Run button
    /// that is exactly how they were read. Empty slots behind them give the
    /// filled ones something to be part of.
    private static let slots = 8

    private var shown: [Tick] {
        ticks.count > limit ? Array(ticks.suffix(limit)) : ticks
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<max(0, Self.slots - shown.count), id: \.self) { _ in
                Capsule()
                    .fill(Theme.border.opacity(0.5))
                    .frame(width: width, height: height)
            }
            ForEach(shown) { tick in
                Capsule()
                    .fill(RunOutcome.tint(tick.status))
                    .frame(width: width, height: height)
                    .opacity(tick.status == "ok" ? 0.85 : 1)
                    .help(tick.label)
                    .onTapGesture { onSelect?(tick) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        if shown.isEmpty { return "Never run" }
        let failed = shown.filter { $0.status == "error" }.count
        if failed == 0 { return "Last \(shown.count) runs, none failed" }
        return "Last \(shown.count) runs, \(failed) failed"
    }
}

/// How long a run took, relative to the longest one beside it.
///
/// A forty-minute run and a forty-second one were the same row. The bar is
/// deliberately relative rather than absolute: the question a list of runs
/// answers is "which of these was the long one", not "how many seconds".
struct DurationBar: View {
    var seconds: Double
    var longest: Double
    var width: CGFloat = 44
    var height: CGFloat = 4

    private var fraction: Double {
        guard longest > 0, seconds > 0 else { return 0 }
        return min(1, max(0.06, seconds / longest))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Theme.border)
                .frame(width: width, height: height)
            Capsule()
                .fill(Theme.accent.opacity(0.7))
                .frame(width: width * fraction, height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: String {
        guard seconds > 0 else { return "Still running" }
        if seconds < 60 { return "Took \(Int(seconds))s" }
        if seconds < 3600 { return "Took \(Int(seconds / 60))m" }
        let hours = seconds / 3600
        return String(format: "Took %.1fh", hours)
    }
}
