// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// The year of activity, sized for a thumb.
///
/// A phone variant rather than `HeatmapView` because that one solves for a
/// width: it shrinks the cell until the whole year fits the window, which on a
/// 402 point screen lands near six points a day. Six points draws a year, and
/// nobody can tap a day in it. So the cell is fixed and the grid scrolls,
/// opening on the most recent week.
///
/// **The cell size is deliberately not fitted to the width.** Growing it to
/// fill the card needs the width to pick the cell, and the height then follows
/// the cell, so the view ends up measuring itself: the first pass has no
/// measurement, lays out at the minimum, reports its own over-wide content as
/// the available width, and every card on Home is dragged off the screen by the
/// next pass. A fixed cell has a constant height and no feedback loop.
///
/// The drawing is one `Canvas`, same as the Mac's, for the same reason: a view
/// per day is hundreds of views re-laid out on every scroll frame.
struct PhoneHeatmap: View {
    let calendar: ActivityCalendar
    /// Tapped day, for the detail sheet. Nil while nothing is selected.
    var onSelect: ((HeatCell) -> Void)?

    /// Big enough to hit, small enough that a season fits on screen.
    private let cell: CGFloat = 15
    private let gap: CGFloat = 3.5
    private let corner: CGFloat = 3
    /// Room for the weekday letters down the leading edge.
    private let gutter: CGFloat = 16
    /// The month row's height, which the weekday letters are pushed down by so
    /// the two line up.
    private let monthRow: CGFloat = 13

    private var step: CGFloat { cell + gap }
    private var gridHeight: CGFloat { step * 7 - gap }
    private var gridWidth: CGFloat { step * CGFloat(calendar.weeks) - gap }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            weekdayLabels
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    monthLabels
                    grid
                }
            }
            // Opens on the most recent week, which is the part anybody wants
            // first.
            .defaultScrollAnchor(.trailing)
            // No soft fade at the scroll edges. That effect exists so content
            // dissolves under glass chrome, and there is no chrome here: this
            // lives inside an opaque card, where the fade only washed out the
            // leading third of the grid.
            .scrollEdgeEffectHidden(true, for: .all)
        }
        .frame(height: monthRow + 6 + gridHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity calendar")
        // The grid's own summary, so VoiceOver does not have to walk a year of
        // cells to learn what it is looking at.
        .accessibilityValue(summary)
    }

    private var summary: String {
        "\(calendar.activeDays) active days, \(formatSpend(calendar.total)) at list rates, "
            + "\(calendar.first) to \(calendar.last)"
    }

    /// The activity ramp, with a quiet day that can actually be seen.
    ///
    /// `Theme.heat` is the website's ramp and its first step is `#ECEAF2`,
    /// which sits on a Mac's panel colour perfectly well and all but vanishes
    /// on a white card at arm's length. A grid whose quiet half is invisible
    /// does not read as "nothing happened those weeks", it reads as a control
    /// that failed to draw, which is exactly how it was reported.
    ///
    /// Only step zero changes. The four active steps stay the brand's own, so
    /// a busy week on the phone is the same colour as a busy week on the site.
    private var heat: [Color] {
        var ramp = Theme.heat
        ramp[0] = Color.adaptive(
            light: Color(red: 0xDE / 255, green: 0xDA / 255, blue: 0xEA / 255),
            dark: Color(red: 0x22 / 255, green: 0x1E / 255, blue: 0x36 / 255)
        )
        return ramp
    }

    private var weekdayLabels: some View {
        // Monday, Wednesday, Friday only. Seven letters at this size is a
        // column of noise beside the thing it labels.
        VStack(spacing: gap) {
            // Pushed down by the month row so the letters line up with rows.
            //
            // **The width matters.** A `Color` with only a height set is
            // flexible horizontally and takes everything offered, so this
            // spacer alone stretched the label column across half the card and
            // squeezed the grid into what was left. That is what "the heatmap
            // only uses half the width" was: not the data, not the scroll
            // position, one missing dimension on a clear rectangle.
            Color.clear.frame(width: gutter, height: monthRow)
            ForEach(0..<7, id: \.self) { row in
                Text(Self.rowLabel(row))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: gutter, height: cell, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private var monthLabels: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: monthRow)
            ForEach(calendar.months) { month in
                Text(month.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(month.column) * step)
            }
        }
        .frame(width: gridWidth, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let ramp = heat
        return Canvas { context, _ in
            for (rowIndex, row) in calendar.rows.enumerated() {
                for (colIndex, day) in row.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(
                        x: CGFloat(colIndex) * step,
                        y: CGFloat(rowIndex) * step,
                        width: cell,
                        height: cell
                    )
                    let level = min(max(day.level, 0), ramp.count - 1)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: corner),
                        with: .color(ramp[level])
                    )
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .contentShape(.rect)
        .gesture(
            SpatialTapGesture().onEnded { event in
                guard let day = day(at: event.location) else { return }
                onSelect?(day)
            }
        )
        // Rebuilt as a flat list so a screen reader gets days rather than a
        // canvas, without the app drawing a year of real views to get them.
        .accessibilityChildren {
            ForEach(accessibleDays) { day in
                Button {
                    onSelect?(day)
                } label: {
                    Text("\(day.date): \(formatSpend(day.value)) at list rates")
                }
            }
        }
    }

    /// Which day a tap landed on, using the same packing the canvas drew with.
    private func day(at point: CGPoint) -> HeatCell? {
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard row >= 0, row < calendar.rows.count else { return nil }
        let cells = calendar.rows[row]
        guard column >= 0, column < cells.count else { return nil }
        return cells[column] ?? nil
    }

    private var accessibleDays: [HeatCell] {
        calendar.rows.flatMap { $0.compactMap { $0 } }
    }

    private static func rowLabel(_ row: Int) -> String {
        switch row {
        case 0: return "M"
        case 2: return "W"
        case 4: return "F"
        default: return ""
        }
    }
}

#endif
