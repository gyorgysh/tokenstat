// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
import UIKit
#endif

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

    /// The day under the finger right now.
    ///
    /// A 15 point square under a thumb is covered by the thumb, so a tap on
    /// this grid is a guess until the sheet opens. Holding names the day
    /// before anything happens, and lifting opens the one being named: the
    /// same gesture whether it lasted a moment or a second, with the answer
    /// visible for as long as the finger is down.
    @State private var focus: Focus?
    /// The last point a finger touched, kept so the hold knows where it began.
    @State private var touch: CGPoint = .zero
    /// A hold is in progress: the grid stops scrolling and follows the finger.
    @State private var scrubbing = false
    /// Set for a moment after a hold, so the lift that ended it does not also
    /// count as a tap.
    @State private var suppressTap = false

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
            // While a finger is scrubbing the grid, the grid is not a scroller.
            // This is what lets the hold own the touch without a composed
            // gesture having to win an argument with the scroll view.
            .scrollDisabled(scrubbing)
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
        .accessibilityHint("Hold a day to read its date and amount, lift to open it")
    }

    private var summary: String {
        "\(calendar.activeDays) active days, \(formatSpend(calendar.total)) at list rates, "
            + "\(spokenDate(calendar.first)) to \(spokenDate(calendar.last)). "
            // Says what is inside, because what is inside is not every square.
            // See `accessibleDays`.
            + "Days with activity are listed."
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
        let marked = focus
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
            // The ring is drawn last so it sits over its neighbours, and it is
            // drawn outside the square so it does not hide the colour it is
            // pointing at.
            if let marked {
                let ring = marked.rect.insetBy(dx: -2, dy: -2)
                context.stroke(
                    Path(roundedRect: ring, cornerRadius: corner + 2),
                    with: .color(Theme.accent),
                    lineWidth: 2
                )
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .contentShape(.rect)
        .overlay(alignment: .topLeading) { readout }
        // Three gestures, all simultaneous, because a composed one had to be
        // resolved before anything happened and that resolution never came
        // inside a scroll view: the press was swallowed and neither the hold
        // nor the tap fired.
        //
        // Instead: the drag only *records* where the finger is (it never
        // resolves against the scroll), the long press flips scrubbing on, and
        // the scroll is disabled for as long as it is on. See `body`.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { event in
                    touch = event.location
                    guard scrubbing else { return }
                    guard let hit = hit(at: event.location), hit.day.id != focus?.day.id else {
                        return
                    }
                    focus = hit
                    Self.tick()
                }
                .onEnded { event in
                    guard scrubbing else { return }
                    let landed = hit(at: event.location) ?? focus
                    endScrub()
                    guard let landed else { return }
                    onSelect?(landed.day)
                }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.2, maximumDistance: 24)
                .onEnded { _ in
                    scrubbing = true
                    focus = hit(at: touch)
                    Self.tick()
                }
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { event in
                // A hold that ended already opened its day. Without this the
                // lift counts twice and the sheet opens on top of itself.
                guard !suppressTap, !scrubbing else { return }
                guard let landed = hit(at: event.location) else { return }
                onSelect?(landed.day)
            }
        )
        // Rebuilt as a flat list so a screen reader gets days rather than a
        // canvas, without the app drawing a year of real views to get them.
        .accessibilityChildren {
            ForEach(accessibleDays) { day in
                Button {
                    onSelect?(day)
                } label: {
                    // A spoken date, not an ISO string: "twenty twenty six
                    // dash zero eight dash eleven" is not a date anybody
                    // hears. The amount is in the label too, so intensity is
                    // never carried by colour alone.
                    Text("\(spokenDate(day.date)), \(formatSpend(day.value)) at list rates")
                }
            }
        }
    }

    /// Leave scrub mode and let the grid scroll again.
    ///
    /// The tap is muted briefly because the same lift that ends a hold also
    /// completes the tap gesture, and the day has already been opened by then.
    private func endScrub() {
        scrubbing = false
        focus = nil
        suppressTap = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            suppressTap = false
        }
    }

    /// The day under the finger and the square it was drawn in.
    private struct Focus: Equatable {
        var day: HeatCell
        var rect: CGRect
    }

    /// What the finger is on: the date, and what that day cost.
    ///
    /// Sits above the square when there is room and below it when the finger
    /// is near the top row, so the label is never under the hand reading it.
    @ViewBuilder
    private var readout: some View {
        if let focus {
            // Clear of the fingertip, not just clear of the square. A label two
            // points above the cell is a label under the same finger that is
            // pointing at it, so it sits a row and a half up and only drops
            // below when the top rows leave no room for that.
            let above = focus.rect.minY >= 38
            Text("\(shortDate(focus.day.date)) · \(formatSpend(focus.day.value))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.85)))
                .fixedSize()
                .offset(
                    x: max(0, min(gridWidth - 120, focus.rect.midX - 60)),
                    y: above ? focus.rect.minY - 38 : focus.rect.maxY + 8
                )
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Which day a touch landed on, using the same packing the canvas drew
    /// with. Points between squares round to the square they are nearest, so a
    /// finger dragged across the grid never lands on nothing.
    private func hit(at point: CGPoint) -> Focus? {
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard row >= 0, row < calendar.rows.count else { return nil }
        let cells = calendar.rows[row]
        guard column >= 0, column < cells.count else { return nil }
        guard let day = cells[column] ?? nil else { return nil }
        let rect = CGRect(
            x: CGFloat(column) * step,
            y: CGFloat(row) * step,
            width: cell,
            height: cell
        )
        return Focus(day: day, rect: rect)
    }

    /// One light tap as the finger crosses into another day. The grid gives no
    /// other feedback that the selection moved while a thumb is covering it.
    private static func tick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The days a screen reader can reach: the ones something happened on.
    ///
    /// A year is 365 focusable squares, and three hundred of them would say
    /// "nothing". Walking that to find last Tuesday is a maze, which is the
    /// thing the accessibility notes in `docs/ios-client-ui.md` name outright.
    /// The quiet days are not hidden information: the summary above carries the
    /// span and the active-day count, and the day sheet gives exact figures for
    /// any day at all.
    private var accessibleDays: [HeatCell] {
        calendar.rows.flatMap { $0.compactMap { $0 } }
            .filter { $0.value > 0 }
            .sorted { $0.date > $1.date }
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
