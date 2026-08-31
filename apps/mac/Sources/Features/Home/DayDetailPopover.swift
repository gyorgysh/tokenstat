// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The day hover card, the same information the profile page shows.
///
/// Presented at the window root rather than inside the heatmap card, so it
/// always draws above the sidebar and every pane, and placed beside the cell
/// on whichever side has room.
struct DayDetailPopover: View {
    var detail: DayDetail?
    var isLoading: Bool
    /// The hovered cell's frame in `HeatmapView.coordinateSpace`.
    var anchor: HoveredCellFrame?
    /// The window's content size, to keep the card inside it.
    var windowSize: CGSize

    private let margin: CGFloat = 8
    /// Side clearance, so the card never touches the window edge. Larger than
    /// a hairline inset: at compact window sizes the card must still read as
    /// floating rather than flush against the chrome.
    private let edgeInset: CGFloat = 16

    var body: some View {
        Group {
            if let detail, let anchor {
                card(detail)
            } else if isLoading, let anchor {
                loadingCard
            } else {
                EmptyView()
            }
        }
        // `.position` centres the view at the point, so the offset math below
        // has to work in the card's own half-extents.
        .position(
            x: clampedX,
            y: clampedY
        )
        .animation(.easeOut(duration: 0.14), value: anchor)
        .allowsHitTesting(false)
    }

    // MARK: - Placement

    /// Preferred side: the popover opens away from the window's middle, so a
    /// cell on the left gets its card on the right and vice versa. Falls back
    /// to the other side when the preferred one is too narrow.
    private var preferredLeft: Bool {
        guard let anchor else { return false }
        return anchor.frame.midX > windowSize.width * 0.5
    }

    private var cardWidth: CGFloat {
        min(320, max(240, windowSize.width - 2 * edgeInset))
    }

    private var cardHeight: CGFloat {
        min(330, max(180, windowSize.height - 2 * edgeInset))
    }

    private var clampedX: CGFloat {
        guard let anchor else { return windowSize.width / 2 }
        let width = cardWidth
        // `.position` centres the card, so the candidate is the card's centre
        // for a card that sits fully beside the cell: half the card's width
        // beyond the margin, not the margin itself. Treating the margin as the
        // centre is what made the card straddle the cell.
        let candidate = preferredLeft
            ? anchor.frame.minX - margin - width / 2   // card sits to the left
            : anchor.frame.maxX + margin + width / 2   // card sits to the right
        let flipped = preferredLeft
            ? anchor.frame.maxX + margin + width / 2
            : anchor.frame.minX - margin - width / 2
        let x = (candidate - width / 2 >= edgeInset
            && candidate + width / 2 <= windowSize.width - edgeInset)
            ? candidate
            : flipped
        // Last resort: a window narrower than the card. Clamp rather than run
        // off either edge. `position` takes the card's center, not its leading
        // edge. Keeping the half-width in these bounds is what leaves the
        // intended margin on both sides at a compact resolution.
        let minimum = edgeInset + width / 2
        let maximum = max(minimum, windowSize.width - edgeInset - width / 2)
        return min(max(x, minimum), maximum)
    }

    private var clampedY: CGFloat {
        guard let anchor else { return windowSize.height / 2 }
        // Vertically centred on the hovered row, so the card reads as
        // belonging to the day under the pointer whatever its height. This is
        // the placement that felt closest; earlier "edge below the cell"
        // versions drifted hundreds of points down because the loading card
        // is much shorter than the full one.
        let desired = anchor.frame.midY
        let minimum = edgeInset + cardHeight / 2
        let maximum = max(minimum, windowSize.height - edgeInset - cardHeight / 2)
        return min(max(desired, minimum), maximum)
    }

    // MARK: - Card

    private func card(_ detail: DayDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SELECTED DAY")
                .font(Theme.font(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)

            Text(Self.friendlyDate(detail.date))
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(detail.value.formatted)
                    .font(Theme.numeric(14, weight: .medium))
                if !detail.estimated {
                    Text("at list rates")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Text("\(formatTokens(detail.tokens)) tokens · \(Self.int(detail.events)) requests")
                .font(Theme.caption)
                .foregroundStyle(.secondary)

            if !detail.rows.isEmpty {
                ThemeRule()
                rows(detail)
                if detail.rows.count > Self.maxRows {
                    Text("+\(detail.rows.count - Self.maxRows) more")
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                split(detail)
            }
        }
        .padding(12)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: Theme.shadow(0.22), radius: 18, y: 6)
    }

    private static let maxRows = 8

    @ViewBuilder
    private func rows(_ detail: DayDetail) -> some View {
        // The rows area is the only part that scrolls: a day with many
        // model × harness slices must not push the card past the window.
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(detail.rows.prefix(Self.maxRows))) { part in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Self.dotColor(part))
                            .frame(width: 6, height: 6)
                        Text("\(shortModel(part.model)) · \(harnessName(harnessToolKey(part.src)))")
                            .font(Theme.font(11))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Text(formatTokens(part.tokens))
                            .font(Theme.numeric(11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.rowsMaxHeight)
    }

    private static let rowsMaxHeight: CGFloat = 150

    /// The input/output/cache split, as a bar and a key, exactly like the
    /// profile page's day hover.
    private func split(_ detail: DayDetail) -> some View {
        let total = detail.rows.reduce(
            into: (fresh: UInt64(0), cacheRead: UInt64(0), cacheWrite: UInt64(0), output: UInt64(0))
        ) { acc, part in
            acc.fresh += part.fresh ?? 0
            acc.cacheRead += part.cacheRead ?? 0
            acc.cacheWrite += (part.cacheWrite5m ?? 0) + (part.cacheWrite1h ?? 0)
            acc.output += part.output ?? 0
        }
        let grand = total.fresh + total.cacheRead + total.cacheWrite + total.output
        guard grand > 0 else { return AnyView(EmptyView()) }

        let segments: [(label: String, value: UInt64, color: Color)] = [
            ("cache read", total.cacheRead, Theme.heat[1]),
            ("cache write", total.cacheWrite, Theme.heat[2]),
            ("output", total.output, Theme.heat[4]),
            ("fresh in", total.fresh, Theme.accent),
        ].filter { $0.value > 0 }
        let barMax = max(2, cardWidth - 24)
        let widths = segments.map { max(2, barMax * CGFloat($0.value) / CGFloat(grand)) }

        return AnyView(
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(segments.indices, id: \.self) { index in
                        Capsule()
                            .fill(segments[index].color)
                            .frame(height: 4)
                            .frame(width: widths[index])
                    }
                }
                HStack(spacing: 8) {
                    ForEach(segments, id: \.label) { segment in
                        Text("\(segment.label) \(Int(round(100 * Double(segment.value) / Double(grand))))%")
                            .font(Theme.font(9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        )
    }

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading day…")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: cardWidth, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: Theme.shadow(0.22), radius: 18, y: 6)
    }

    // MARK: - Helpers

    private static func dotColor(_ part: DayPart) -> Color {
        let palette = [Theme.accent, Theme.heat[4], Theme.heat[3], Theme.heat[2], Theme.heat[1]]
        // Stable per pair, so a row keeps its colour when the list reorders.
        let seed = abs(part.id.hashValue) % palette.count
        return palette[seed]
    }

    private static func friendlyDate(_ iso: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale.current
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }

    private static func int(_ n: UInt64) -> String {
        n.formatted(.number)
    }
}
