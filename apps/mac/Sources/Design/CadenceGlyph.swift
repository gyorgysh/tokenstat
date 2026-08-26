// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A schedule as a shape rather than a sentence.
///
/// The model already carries the rhythm: a kind, and a bitmask of days where
/// the kind has days. The screen spent all of that on the string "weekdays at
/// 09:00", which you have to read word by word and cannot compare against the
/// job under it. Seven dots around a ring, the live ones filled, answers "when
/// does this fire" before the eye reaches the name.
///
/// Monday is the top dot and the week runs clockwise, matching the bitmask the
/// host uses (Monday = bit 0).
struct CadenceGlyph: View {
    var schedule: AutomationSchedule
    /// A paused job draws in the idle tint. It still has a rhythm, it just is
    /// not keeping it.
    var enabled: Bool = true
    var size: CGFloat = 22
    /// The words this replaces. Callers pass `scheduleSummary`, which is the
    /// one place that phrasing is decided.
    var summary: String = ""

    private var tint: Color { enabled ? Theme.accent : Theme.stateIdle }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.isEmpty ? schedule.kind.label : summary)
            .help(summary.isEmpty ? schedule.kind.label : summary)
    }

    @ViewBuilder
    private var content: some View {
        switch schedule.kind {
        case .once:
            symbol("play.circle")
        case .interval:
            symbol("arrow.triangle.2.circlepath")
        case .daily, .weekdays, .weekly, .custom:
            weekRing
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(Theme.font(size * 0.82, weight: .regular))
            .foregroundStyle(tint)
    }

    private var weekRing: some View {
        let dot = max(3, size * 0.19)
        let radius = (size - dot) / 2
        return ZStack {
            Circle()
                .strokeBorder(Theme.border, lineWidth: 1)
            ForEach(0..<7, id: \.self) { day in
                Circle()
                    .fill(fires(on: day) ? tint : Theme.stateIdle.opacity(0.28))
                    .frame(width: dot, height: dot)
                    .offset(
                        x: radius * sin(Double(day) / 7 * 2 * .pi),
                        y: -radius * cos(Double(day) / 7 * 2 * .pi)
                    )
            }
        }
    }

    /// 0 is Monday, matching `AutomationSchedule.weekdays` and `weekday`.
    private func fires(on day: Int) -> Bool {
        switch schedule.kind {
        case .daily:
            return true
        case .weekdays:
            return day < 5
        case .weekly:
            // The host accepts a weekly schedule either way and sends both, so
            // prefer the bitset when it carries days. `scheduleSummary` makes
            // the same choice, and the ring must not contradict the words it
            // sits beside.
            if schedule.weekdays & 0b0111_1111 != 0 {
                return schedule.weekdays & (1 << day) != 0
            }
            return day == schedule.weekday
        case .custom:
            return schedule.weekdays & (1 << day) != 0
        case .once, .interval:
            return false
        }
    }
}

/// How much of the wait until the next run is already spent.
///
/// "Next Aug 17, 2026 at 09:00" is a date you have to subtract today from. A
/// ring that is nearly closed says "soon" with no arithmetic.
struct CountdownRing: View {
    /// Usually the last run. Without it the ring cannot show progress, so it
    /// draws empty and the words beside it carry the meaning.
    var start: Date?
    var end: Date
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5

    var body: some View {
        // Reading a phrase from the shared clock is what subscribes this view
        // to the tick. See `RelativeClock`: a per-view live date costs a window
        // layout pass every frame.
        let words = RelativeClock.phrase(for: end, style: .abbreviated)
        return ZStack {
            Circle()
                .strokeBorder(Theme.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next run \(words)")
        .help("Next run \(words)")
    }

    private var fraction: Double {
        guard let start else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        let done = Date().timeIntervalSince(start)
        return min(1, max(0, done / total))
    }
}

/// The countdown ring with the words it stands for, for rows that have space.
struct NextRunBadge: View {
    var start: Date?
    var end: Date

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            CountdownRing(start: start, end: end)
            Text(RelativeClock.phrase(for: end, style: .abbreviated))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Concurrency as places at a table, filled by what is running now.
///
/// "Max concurrent jobs: 2" is a setting. Two tiles with one lit is a picture
/// of the queue, and it tells you the next job is going to wait.
struct SlotGauge: View {
    var filled: Int
    var total: Int
    /// Zero concurrent means no cap on the host, which has no shape at all, so
    /// say so in words instead of drawing an infinite row of tiles.
    var uncapped: Bool = false
    var tile: CGFloat = 10

    /// Tiles actually drawn.
    ///
    /// The number comes from a text field somebody is still typing into, so it
    /// has to be bounded: `100000` is a valid thing to type and a hundred
    /// thousand rectangles in an HStack hangs the window before the value is
    /// ever saved. Past this many the count is words, not shapes.
    private static let maxTiles = 12

    private var drawn: Int {
        min(max(total, 1), Self.maxTiles)
    }

    var body: some View {
        HStack(spacing: 3) {
            if uncapped {
                Text("No cap")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(0..<drawn, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index < filled ? Theme.accent : Theme.border)
                        .frame(width: tile, height: tile)
                }
                if total > drawn {
                    Text("+\(total - drawn)")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: String {
        if uncapped { return "No limit on jobs at once" }
        return "\(filled) of \(total) slots busy"
    }
}

