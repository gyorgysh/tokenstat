// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import SwiftUI

enum TurnElapsed {
    static func phrase(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return L10n.text("apple.chatturntiming.0_s.c4c041f8", "\(seconds)") }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.text("apple.chatturntiming.0_m.7f5ea983", "\(minutes)") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? L10n.text("apple.chatturntiming.0_h.360a8af5", "\(hours)") : L10n.text("apple.chatturntiming.0_h_1_m.d426ce3b", "\(hours)", "\(rest)")
    }

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

struct TurnElapsedText: View {
    let since: Date
    var prefix = L10n.text("common.working")

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text("\(prefix) · \(TurnElapsed.phrase(since: since, now: context.date))")
                .accessibilityLabel(L10n.text("apple.chatturntiming.0_for_1.b1e4faa4", "\(prefix)", "\(TurnElapsed.durationWords(since: since, now: context.date))"))
        }
    }
}
