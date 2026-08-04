// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The activity grid: a year of days, a column per week.
///
/// The grid arrives built from `tokenstat_core::activity`, which is the same
/// code the CLI draws from. This view places squares and nothing else. It must
/// not compute which day belongs in which column: the archive stores only days
/// that had events, so anything that packs them together draws a plausible
/// calendar with every date in the wrong place.
struct HeatmapView: View {
    let calendar: ActivityCalendar
    /// Clicking a day filters Insights to it.
    var onSelect: ((HeatCell) -> Void)?

    @State private var hovered: HeatCell?

    private let gap: CGFloat = 3
    private let gutter: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // The cell size comes from the width available, so the grid always
            // spans the card. It used to be a fixed 11 points inside a
            // horizontal scroll view anchored trailing, which on a wide window
            // drew a year of squares against the right edge and left half the
            // card empty.
            GeometryReader { proxy in
                let cell = cellSize(for: proxy.size.width)
                VStack(alignment: .leading, spacing: gap) {
                    months(cell: cell)
                    ForEach(0 ..< calendar.rows.count, id: \.self) { row in
                        HStack(spacing: gap) {
                            Text(Self.rowLabel(row))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: gutter, alignment: .leading)
                            ForEach(0 ..< calendar.rows[row].count, id: \.self) { column in
                                square(calendar.rows[row][column], cell: cell)
                            }
                        }
                    }
                }
            }
            .frame(height: gridHeight)

            footer
        }
    }

    /// Square size that makes seven rows of `weeks` columns fill the width.
    ///
    /// Clamped at both ends: below about seven points the levels stop being
    /// distinguishable, and above about eighteen a year of days reads as a
    /// wall of tiles rather than a calendar.
    private func cellSize(for width: CGFloat) -> CGFloat {
        guard calendar.weeks > 0, width > 0 else { return 11 }
        let available = width - gutter - gap
        let fitted = (available / CGFloat(calendar.weeks)) - gap
        return min(max(fitted, 7), 18)
    }

    /// Reserved height: the month strip, then seven rows.
    ///
    /// Fixed rather than measured, because the grid is inside a `GeometryReader`
    /// and a reader that sizes itself from its own content has nothing to read.
    private var gridHeight: CGFloat {
        11 + gap + 7 * (18 + gap)
    }

    private func months(cell: CGFloat) -> some View {
        // Absolute placement rather than a stack of spacers: a month label is
        // wider than the column it belongs to, so laying them out in sequence
        // pushes every later one out of alignment with its week.
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 11)
            ForEach(calendar.months) { month in
                Text(month.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .offset(x: gutter + gap + CGFloat(month.column) * (cell + gap))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func square(_ day: HeatCell?, cell: CGFloat) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Theme.heat[min(day.level, Theme.heat.count - 1)])
                .frame(width: cell, height: cell)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(
                            hovered == day ? Color.primary.opacity(0.55) : .clear,
                            lineWidth: 1
                        )
                )
                .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
                .onTapGesture { onSelect?(day) }
                .help("\(day.date): \(formatTokens(day.value)) tokens")
        } else {
            // A day after today. Left blank rather than drawn as idle: it has
            // not happened, which is not the same as nothing happening.
            Color.clear.frame(width: cell, height: cell)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if let day = hovered {
                Text("\(day.date)")
                    .font(Theme.numeric(11))
                    .foregroundStyle(.secondary)
                Text(formatTokens(day.value))
                    .font(Theme.numeric(11, weight: .medium))
            } else {
                Text("\(calendar.first) to \(calendar.last)")
                    .font(Theme.numeric(11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("Less")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            ForEach(0 ..< Theme.heat.count, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.heat[level])
                    .frame(width: 9, height: 9)
            }
            Text("More")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// Only alternate rows are labelled, so the gutter stays quiet. Same choice
    /// the CLI makes.
    private static func rowLabel(_ row: Int) -> String {
        switch row {
        case 0: return "Mon"
        case 2: return "Wed"
        case 4: return "Fri"
        default: return ""
        }
    }
}
