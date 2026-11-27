// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
    var onSelect: ((HeatCell) -> Void)?
    var selectedDate: String?
    var onHover: ((HeatCell?) -> Void)?

    @State private var hovered: HoveredSlot?

    static let coordinateSpace = "tokenstat.window"

    private let gutter: CGFloat = 30
    private let gapRatio: CGFloat = 0.2
    private let cellCorner: CGFloat = 2.5

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HeatmapFittedLayout(heightForWidth: gridHeight(for:)) {
                GeometryReader { proxy in
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }

            footer
        }
        #if !os(macOS)
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            ForEach(accessibleDays, id: \.day.date) { item in
                Button { onSelect?(item.day) } label: {
                    Text(L10n.text("apple.heatmapview.0_1_at_api_list_price.1a0524d3", "\(item.day.date)", "\(formatSpend(item.day.value))"))
                }
                .accessibilityHint(L10n.text("apple.heatmapview.pins_this_day_in_the_inspector.f1c6b2a5"))
            }
        }
        #endif
    }

    private let maxCell: CGFloat = 16

    private func cellSize(for width: CGFloat) -> CGFloat {
        guard calendar.weeks > 0, width > 0 else { return 11 }
        let columns = CGFloat(calendar.weeks)
        let fitted = (width - gutter) / (gapRatio + columns * (1 + gapRatio))
        return min(max(fitted, 7), maxCell)
    }

    private func gapSize(for width: CGFloat, cell: CGFloat) -> CGFloat {
        guard calendar.weeks > 0, width > 0 else { return cell * gapRatio }
        let columns = CGFloat(calendar.weeks)
        let spare = (width - gutter - columns * cell) / (columns + 1)
        return min(max(spare, cell * gapRatio), cell * maxGapRatio)
    }

    private let maxGapRatio: CGFloat = 0.5

    private func gridHeight(for proposedWidth: CGFloat) -> CGFloat {
        let width = quantised(proposedWidth, step: 4)
        let cell = cellSize(for: width)
        let gap = gapSize(for: width, cell: cell)
        return 11 + CGFloat(calendar.rows.count) * (cell + gap)
    }

    private func months(layout: GridLayout) -> some View {
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
            HeatmapCellsCanvas(rows: calendar.rows, cell: layout.cell,
                               gap: layout.gap, corner: corner, palette: heat)
                .equatable()
            .allowsHitTesting(false)

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
        #if os(macOS)
        .background {
            HeatmapAccessibilityView(rows: calendar.rows, cell: layout.cell, gap: layout.gap, onSelect: onSelect)
                .allowsHitTesting(false)
        }
        #endif
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
                    Text(L10n.text("apple.heatmapview.0_to_1.c1e3e989", "\(calendar.first)", "\(calendar.last)"))
                        .font(Theme.numeric(11))
                        .foregroundStyle(.tertiary)
                    if let freshness = calendar.freshness {
                        Text("· \(freshness)")
                            .font(Theme.font(11))
                            .foregroundStyle(calendar.isStaleGrid ? Theme.warning : Color.secondary.opacity(0.8))
                    }
                }

                Spacer()

                Text(L10n.text("apple.heatmapview.less.ae5239ec"))
                    .font(Theme.font(10))
                    .foregroundStyle(.tertiary)
                ForEach(0 ..< Theme.heat.count, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.heat[level])
                        .frame(width: 9, height: 9)
                }
                Text(L10n.text("apple.heatmapview.more.d47d7cb0"))
                    .font(Theme.font(10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func rowLabel(_ row: Int) -> String {
        switch row {
        case 0: return L10n.text("apple.heatmapview.mon.f40d7f51")
        case 2: return L10n.text("apple.heatmapview.wed.58339f45")
        case 4: return L10n.text("apple.heatmapview.fri.66dab40c")
        default: return ""
        }
    }
}

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

    func slot(at point: CGPoint, in rows: [[HeatCell?]]) -> HoveredSlot? {
        guard point.x >= 0, point.y >= 0, cell > 0 else { return nil }
        let column = Int(point.x / stride)
        let row = Int(point.y / stride)
        guard row >= 0, row < rows.count else { return nil }
        guard column >= 0, column < rows[row].count else { return nil }
        let localX = point.x - CGFloat(column) * stride
        let localY = point.y - CGFloat(row) * stride
        guard localX <= cell, localY <= cell else { return nil }
        guard let day = rows[row][column], !day.isLocked else { return nil }
        return HoveredSlot(day: day, row: row, column: column)
    }
}

private struct HoveredSlot: Equatable {
    var day: HeatCell
    var row: Int
    var column: Int
}

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

struct HeatmapCellsCanvas: View, Equatable {
    let rows: [[HeatCell?]]
    let cell: CGFloat
    let gap: CGFloat
    let corner: CGFloat
    let palette: [Color]

    var body: some View {
        Canvas { context, _ in
            guard !palette.isEmpty else { return }
            var paths = Array(repeating: Path(), count: palette.count * 2)
            for (rowIndex, row) in rows.enumerated() {
                for (column, day) in row.enumerated() {
                    guard let day else { continue }
                    let level = min(max(day.level, 0), palette.count - 1)
                    let rect = CGRect(x: CGFloat(column) * (cell + gap),
                                      y: CGFloat(rowIndex) * (cell + gap),
                                      width: cell, height: cell)
                    let bucket = level * 2 + (day.isLocked ? 1 : 0)
                    paths[bucket].addRoundedRect(in: rect,
                        cornerSize: CGSize(width: corner, height: corner))
                }
            }
            for (bucket, path) in paths.enumerated() where !path.isEmpty {
                context.fill(path, with: .color(
                    palette[bucket / 2].opacity(bucket.isMultiple(of: 2) ? 1 : 0.28)))
            }
        }
    }
}

private struct HeatmapFittedLayout: Layout {
    var heightForWidth: (CGFloat) -> CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: width, height: heightForWidth(width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
