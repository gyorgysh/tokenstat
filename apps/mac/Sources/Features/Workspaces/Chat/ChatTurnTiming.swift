// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import SwiftUI

/// How long the current turn has been running, in words.
///
/// A turn is measured from the last chat instruction to now, across every
/// agent step inside it: not per tool call, not per model round trip. The
/// host reports only whether a conversation is running, so the start is the
/// moment this app first saw it running: exact for a turn sent from here,
/// and a lower bound for one already going when the app opened or the folder
/// was last read.
enum TurnElapsed {
    /// "10s", "3m", "1h 5m". Floored, never rounded up: a turn that has run
    /// 59.9 seconds has not run a minute yet.
    static func phrase(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "10 seconds", "3 minutes", "1 hour 5 minutes". What the compact phrase
    /// above reads as out loud, so a screen reader never meets "3m".
    static func durationWords(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return count(seconds, unit: "second") }
        let minutes = seconds / 60
        if minutes < 60 { return count(minutes, unit: "minute") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? count(hours, unit: "hour")
            : "\(count(hours, unit: "hour")) \(count(rest, unit: "minute"))"
    }

    private static func count(_ value: Int, unit: String) -> String {
        value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
    }
}

/// Reconcile observed turn starts against the conversations known to be
/// running right now.
///
/// Stamps exist exactly for running conversations: a newly running one is
/// stamped with `now` and keeps that stamp while it runs, and anything that
/// stopped, or is no longer known, leaves no stamp. Pure so the rule is
/// unit tested; `ChatModel` feeds it every list it holds.
func reconcileRunningSince(
    _ stamps: [String: Date],
    running: Set<String>,
    now: Date
) -> [String: Date] {
    var next: [String: Date] = [:]
    next.reserveCapacity(running.count)
    for id in running {
        next[id] = stamps[id] ?? now
    }
    return next
}

/// A turn's age, ticking once a second while it is on screen.
///
/// Mount this only while the conversation is running. A static text is drawn
/// when it is not, so nothing ticks for idle rows: the one-second cadence
/// exists solely to count "10s" up, and minute-precise ages already have
/// `RelativeClock`.
struct TurnElapsedText: View {
    let since: Date
    var prefix = "Working"

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text("\(prefix) · \(TurnElapsed.phrase(since: since, now: context.date))")
                .accessibilityLabel("\(prefix) for \(TurnElapsed.durationWords(since: since, now: context.date))")
        }
    }
}
