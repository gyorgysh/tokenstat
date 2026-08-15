// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The day pinned from the Home heatmap: spend, models, and the token split.
///
/// Hover still pops a glance card. A click lives here so leaving Home and
/// coming back keeps the same day, which a view `@State` would not survive.
struct HomeInspector: View {
    var model: HomeModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                Text("Day")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, Theme.Space.m)
                Spacer(minLength: 0)
            }
            Group {
                if let day = model.selectedDay {
                    dayBody(day)
                } else {
                    InspectorEmptyState(
                        systemImage: "square.grid.3x3",
                        title: "Pick a day on the grid",
                        subtitle: "Hover for a glance. Click to pin the day here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private func dayBody(_ day: HeatCell) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if day.isLocked {
                    Text("This day is outside the unlocked window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.isLoadingSelectedDetail, model.selectedDetail == nil {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Loading day…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let detail = model.selectedDetail {
                    detailCard(detail)
                } else {
                    Text("Nothing recorded on this day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailCard(_ detail: DayDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(Self.friendlyDate(detail.date))
                .font(.system(size: 15, weight: .semibold))

            Stat(
                label: "Value at list rates",
                value: detail.value.formatted,
                note: detail.estimated ? "estimated" : "not billed",
                tint: Theme.accent,
                size: 22
            )

            Text("\(formatTokens(detail.tokens)) tokens · \(detail.events.formatted(.number)) requests")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !detail.rows.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(detail.rows) { part in
                        HStack(spacing: Theme.Space.s) {
                            Circle()
                                .fill(Self.dotColor(part))
                                .frame(width: 6, height: 6)
                            Text("\(shortModel(part.model)) · \(harnessName(part.src))")
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(formatTokens(part.tokens))
                                .font(Theme.numeric(12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                split(detail)
            }
        }
    }

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

        return AnyView(
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.label) { segment in
                            Capsule()
                                .fill(segment.color)
                                .frame(
                                    width: max(2, proxy.size.width * CGFloat(segment.value) / CGFloat(grand)),
                                    height: 4
                                )
                        }
                    }
                }
                .frame(height: 4)
                ForEach(segments, id: \.label) { segment in
                    Text("\(segment.label) \(Int(round(100 * Double(segment.value) / Double(grand))))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        )
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

    private static func dotColor(_ part: DayPart) -> Color {
        let palette = [Theme.accent, Theme.heat[4], Theme.heat[3], Theme.heat[2], Theme.heat[1]]
        let seed = abs(part.id.hashValue) % palette.count
        return palette[seed]
    }
}
