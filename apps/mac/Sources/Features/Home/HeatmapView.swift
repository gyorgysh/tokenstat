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
/// code the CLI draws from. A square's shade is its day's value at list rates,
/// so the grid reads as where the money went rather than where the tokens went,
/// and matches the profile page on the website. This view places squares and
/// nothing else, taking the level as given. It must
/// not compute which day belongs in which column: the archive stores only days
/// that had events, so anything that packs them together draws a plausible
/// calendar with every date in the wrong place.
///
/// Drawing is a single `Canvas` (~370 cells in one layer) rather than one
/// SwiftUI view per day. A view-per-cell grid re-laid out on every scroll
/// frame and each cell carried its own `GeometryReader` for the hover
/// popover, which is what made Home lag when the pointer was over the card.
/// Hit testing, hover, and the popover anchor are one overlay that maps a
/// point back to a cell with the same packing math.
struct HeatmapView: View {
    let calendar: ActivityCalendar
    /// Clicking a day pins it in the inspector.
    var onSelect: ((HeatCell) -> Void)?
    /// The day currently pinned, so the grid can mark it.
    var selectedDate: String?
    /// The pointer moved over (or left) a day. The parent owns the detail
    /// fetch and the popover, so this only carries which cell it is.
    var onHover: ((HeatCell?) -> Void)?

    @State private var hovered: HoveredSlot?

    /// The named coordinate space the popover reads cell frames in. Set on the
    /// window's root view so a frame here is a window-space frame no matter
    /// how deep the heatmap sits in the split view.
    static let coordinateSpace = "tokenstat.window"

    private let gutter: CGFloat = 30
    /// Gap as a fraction of a cell, so the grid keeps its texture at any size.
    /// A fixed 3 point gap between 28 point squares reads as a solid block.
    private let gapRatio: CGFloat = 0.2
    /// Corner radius of each day square, kept in one place so Canvas and the
    /// hover ring agree.
    private let cellCorner: CGFloat = 2.5

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // The cell size comes from the width available, so the grid always
            // spans the card. It used to be a fixed 11 points inside a
            // horizontal scroll view anchored trailing, which on a wide window
            // drew a year of squares against the right edge and left half the
            // card empty.
            GeometryReader { proxy in
                // Quantised before anything is derived from it. There are 371
                // squares here, and a live drag otherwise hands this a new
                // sub-pixel width every frame, each one a new cell size and a
                // new frame for every square. Rounding to 4 points turns most
                // frames of a drag into the same grid.
                let width = quantised(proxy.size.width, step: 4)
                let cell = cellSize(for: width)
                let gap = gapSize(for: width, cell: cell)
                let layout = GridLayout(
                    cell: cell,
                    gap: gap,
                    gutter: gutter,
                    weeks: calendar.weeks,
                    rows: calendar.rows.count
                )
                VStack(alignment: .leading, spacing: gap) {
                    months(layout: layout)
                    HStack(alignment: .top, spacing: gap) {
                        rowLabels(layout: layout)
                        grid(layout: layout)
                    }
                }
                // Centred, not leading. Once the cell and the gap are both at
                // their ceilings a very wide card has width left over, and all
                // of it collecting on one side reads as the grid having failed
                // to reach the edge. `.top` is horizontally centred.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private func months(layout: GridLayout) -> some View {
        // Absolute placement rather than a stack of spacers: a month label is
        // wider than the column it belongs to, so laying them out in sequence
        // pushes every later one out of alignment with its week.
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 11)
            ForEach(calendar.months) { month in
                Text(month.name)
                    .font(Theme.font(9))
                    .foregroundStyle(.tertiary)
                    .offset(x: layout.gutter + layout.gap + CGFloat(month.column) * layout.stride)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowLabels(layout: GridLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            ForEach(0 ..< calendar.rows.count, id: \.self) { row in
                Text(Self.rowLabel(row))
                    .font(Theme.font(9))
                    .foregroundStyle(.tertiary)
                    .frame(width: layout.gutter, height: layout.cell, alignment: .leading)
            }
        }
    }

    /// The year of squares as one canvas, plus a thin hit layer for hover and
    /// click. Accessibility is rebuilt as a flat list of days so VoiceOver does
    /// not need a view per cell either.
    private func grid(layout: GridLayout) -> some View {
        let heat = Theme.heat
        let corner = cellCorner
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for (rowIndex, row) in calendar.rows.enumerated() {
                    for (colIndex, day) in row.enumerated() {
                        guard let day else { continue }
                        let rect = layout.cellRect(row: rowIndex, column: colIndex)
                        let path = Path(
                            roundedRect: rect,
                            cornerRadius: corner
                        )
                        let level = min(max(day.level, 0), heat.count - 1)
                        let fill = heat[level].opacity(day.isLocked ? 0.28 : 1)
                        context.fill(path, with: .color(fill))
                    }
                }
            }
            .allowsHitTesting(false)

            // One ring for the hovered day. Drawn as a real view so it stays
            // crisp on top of the canvas without redrawing every cell.
            if let selected = selectedSlot {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .frame(width: layout.cell, height: layout.cell)
                    .offset(
                        x: layout.cellRect(row: selected.row, column: selected.column).minX,
                        y: layout.cellRect(row: selected.row, column: selected.column).minY
                    )
                    .allowsHitTesting(false)
            }
            if let hovered {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                    .frame(width: layout.cell, height: layout.cell)
                    .offset(
                        x: layout.cellRect(row: hovered.row, column: hovered.column).minX,
                        y: layout.cellRect(row: hovered.row, column: hovered.column).minY
                    )
                    .allowsHitTesting(false)
            }

            // Transparent hit target covering the canvas. Maps pointer location
            // to a cell with the same packing math the canvas uses.
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        setHovered(layout.slot(at: location, in: calendar.rows))
                    case .ended:
                        setHovered(nil)
                    }
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            guard let slot = layout.slot(at: event.location, in: calendar.rows),
                                  !slot.day.isLocked
                            else {
                                return
                            }
                            onSelect?(slot.day)
                        }
                )
        }
        .frame(width: layout.contentWidth, height: layout.contentHeight, alignment: .topLeading)
        // One GeometryReader for the whole grid reports the hovered cell's
        // window frame. Per-cell readers were the other half of the scroll lag.
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: HoveredCellFrameKey.self,
                    value: hoveredFrame(in: geo, layout: layout)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            ForEach(accessibleDays, id: \.day.date) { item in
                Button {
                    onSelect?(item.day)
                } label: {
                    Text("\(item.day.date): \(formatSpend(item.day.value)) at list rates")
                }
                .accessibilityHint("Pins this day in the inspector")
            }
        }
    }

    private var selectedSlot: (row: Int, column: Int)? {
        guard let selectedDate else { return nil }
        for (row, cells) in calendar.rows.enumerated() {
            for (column, day) in cells.enumerated() {
                if day?.date == selectedDate {
                    return (row, column)
                }
            }
        }
        return nil
    }

    /// Days VoiceOver can land on. Future blank cells are skipped; idle days
    /// stay so the grid is still a calendar under a screen reader.
    private var accessibleDays: [(day: HeatCell, row: Int, column: Int)] {
        var out: [(day: HeatCell, row: Int, column: Int)] = []
        for (row, cells) in calendar.rows.enumerated() {
            for (column, day) in cells.enumerated() {
                if let day, !day.isLocked {
                    out.append((day, row, column))
                }
            }
        }
        return out
    }

    private func setHovered(_ slot: HoveredSlot?) {
        // Avoid thrashing the parent hover handler and the popover preference
        // when the pointer stays inside the same square.
        if slot == hovered { return }
        hovered = slot
        onHover?(slot?.day)
    }

    private func hoveredFrame(in geo: GeometryProxy, layout: GridLayout) -> HoveredCellFrame? {
        guard let hovered else { return nil }
        let origin = geo.frame(in: .named(Self.coordinateSpace))
        let local = layout.cellRect(row: hovered.row, column: hovered.column)
        return HoveredCellFrame(
            date: hovered.day.date,
            frame: local.offsetBy(dx: origin.minX, dy: origin.minY)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if calendar.isHistoryLocked {
                HistoryLockBanner(days: calendar.historyDays ?? 30)
            }
            HStack(spacing: Theme.Space.s) {
                if let day = hovered?.day {
                    Text("\(day.date)")
                        .font(Theme.numeric(11))
                        .foregroundStyle(.secondary)
                    Text(formatSpend(day.value))
                        .font(Theme.numeric(11, weight: .medium))
                } else {
                    Text("\(calendar.first) to \(calendar.last)")
                        .font(Theme.numeric(11))
                        .foregroundStyle(.tertiary)
                    if let freshness = calendar.freshness {
                        Text("· \(freshness)")
                            .font(Theme.font(11))
                            .foregroundStyle(calendar.isStaleGrid ? Theme.warning : Color.secondary.opacity(0.8))
                    }
                }

                Spacer()

                Text("Less")
                    .font(Theme.font(10))
                    .foregroundStyle(.tertiary)
                ForEach(0 ..< Theme.heat.count, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.heat[level])
                        .frame(width: 9, height: 9)
                }
                Text("More")
                    .font(Theme.font(10))
                    .foregroundStyle(.tertiary)
            }
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

/// Packing constants for one render of the heatmap grid.
///
/// Built once per layout pass from the measured width, then shared by the
/// canvas, the hit tester, the hover ring, and the popover anchor so those
/// four can never disagree about where a day sits.
private struct GridLayout {
    var cell: CGFloat
    var gap: CGFloat
    var gutter: CGFloat
    var weeks: Int
    var rows: Int

    var stride: CGFloat { cell + gap }

    var contentWidth: CGFloat {
        guard weeks > 0 else { return 0 }
        return CGFloat(weeks) * cell + CGFloat(max(weeks - 1, 0)) * gap
    }

    var contentHeight: CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * cell + CGFloat(max(rows - 1, 0)) * gap
    }

    func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(
            x: CGFloat(column) * stride,
            y: CGFloat(row) * stride,
            width: cell,
            height: cell
        )
    }

    /// Map a point in content coordinates to a day, or nil for a gap / blank
    /// future cell / outside the grid.
    func slot(at point: CGPoint, in rows: [[HeatCell?]]) -> HoveredSlot? {
        guard point.x >= 0, point.y >= 0, cell > 0 else { return nil }
        let column = Int(point.x / stride)
        let row = Int(point.y / stride)
        guard row >= 0, row < rows.count else { return nil }
        guard column >= 0, column < rows[row].count else { return nil }
        // Reject the gap band between cells so moving through a gutter clears
        // the hover rather than sticking to the previous day.
        let localX = point.x - CGFloat(column) * stride
        let localY = point.y - CGFloat(row) * stride
        guard localX <= cell, localY <= cell else { return nil }
        guard let day = rows[row][column], !day.isLocked else { return nil }
        return HoveredSlot(day: day, row: row, column: column)
    }
}

/// The cell under the pointer, with its grid index so the ring and the
/// popover anchor can be placed without scanning the year for a date match.
private struct HoveredSlot: Equatable {
    var day: HeatCell
    var row: Int
    var column: Int
}

/// Where the hovered heatmap cell sits, in window coordinates.
///
/// A small value so the preference key can stay nil when nothing is hovered:
/// the popover reads a nil frame as "hide".
struct HoveredCellFrame: Equatable {
    var date: String
    var frame: CGRect
}

struct HoveredCellFrameKey: PreferenceKey {
    static var defaultValue: HoveredCellFrame?
    static func reduce(value: inout HoveredCellFrame?, nextValue: () -> HoveredCellFrame?) {
        value = nextValue() ?? value
    }
}
