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

    private let gutter: CGFloat = 30
    /// Gap as a fraction of a cell, so the grid keeps its texture at any size.
    /// A fixed 3 point gap between 28 point squares reads as a solid block.
    private let gapRatio: CGFloat = 0.2

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // The cell size comes from the width available, so the grid always
            // spans the card. It used to be a fixed 11 points inside a
            // horizontal scroll view anchored trailing, which on a wide window
            // drew a year of squares against the right edge and left half the
            // card empty.
            GeometryReader { proxy in
                let cell = cellSize(for: proxy.size.width)
                let gap = gapSize(for: proxy.size.width, cell: cell)
                VStack(alignment: .leading, spacing: gap) {
                    months(cell: cell, gap: gap)
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
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: gridHeight)

            footer
        }
    }

    /// The largest a square is allowed to get.
    ///
    /// The grid is seven rows tall whatever the width, so an uncapped cell size
    /// makes a wide window grow the heatmap vertically until it is the tallest
    /// thing on the screen. It also overran the height reserved for it and drew
    /// through the legend underneath.
    private let maxCell: CGFloat = 16

    /// Square size that makes `weeks` columns span the width, up to `maxCell`.
    ///
    /// Solved rather than guessed. With `gap = k·cell` the width is
    /// `gutter + gap + weeks × (cell + gap)`, which rearranges to this. Picking
    /// a size and hoping is what left a year of squares ending two thirds
    /// across a full-screen window.
    ///
    /// The lower bound is real too: under about seven points the five heat
    /// levels stop being distinguishable.
    private func cellSize(for width: CGFloat) -> CGFloat {
        guard calendar.weeks > 0, width > 0 else { return 11 }
        let columns = CGFloat(calendar.weeks)
        let fitted = (width - gutter) / (gapRatio + columns * (1 + gapRatio))
        return min(max(fitted, 7), maxCell)
    }

    /// Gap that spends whatever width the capped cells did not.
    ///
    /// Once the cell hits its ceiling the leftover width has to go somewhere,
    /// and widening the gaps keeps the grid spanning the card without making it
    /// taller. Capped in turn, or a very wide window scatters the squares.
    private func gapSize(for width: CGFloat, cell: CGFloat) -> CGFloat {
        guard calendar.weeks > 0, width > 0 else { return cell * gapRatio }
        let columns = CGFloat(calendar.weeks)
        let spare = (width - gutter - columns * cell) / (columns + 1)
        return min(max(spare, cell * gapRatio), cell * maxGapRatio)
    }

    private let maxGapRatio: CGFloat = 0.5

    /// Reserved height: the month strip, then seven rows at their largest.
    ///
    /// Computed from the ceilings rather than measured, because the grid is
    /// inside a `GeometryReader` and a reader that sizes itself from its own
    /// content has nothing to read. The real grid is never taller than this,
    /// which is the point: it used to be, and it drew over the legend.
    private var gridHeight: CGFloat {
        let gap = maxCell * maxGapRatio
        return 11 + gap + 7 * (maxCell + gap)
    }

    private func months(cell: CGFloat, gap: CGFloat) -> some View {
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
