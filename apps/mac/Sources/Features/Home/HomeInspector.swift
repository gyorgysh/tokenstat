// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The day pinned from the Home heatmap: an Insights-shaped overview.
///
/// Today is pinned when Home first loads. Hover still pops a glance card.
/// A later click lives here so leaving Home and coming back keeps that day,
/// which a view `@State` would not survive.
struct HomeInspector: View {
    var model: HomeModel
    var onOpenInsights: ((String) -> Void)? = nil
    var onClose: () -> Void

    private let listLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                FeatureMark(name: "mark_activity", tint: Theme.accent, size: 16)
                    .padding(.leading, Theme.Space.m)
                Text("Day")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Group {
                if let day = model.selectedDay {
                    dayBody(day)
                } else {
                    InspectorEmptyState(
                        mark: "mark_activity",
                        title: "Today opens here",
                        subtitle: "The heatmap is still loading. Hover a day for a glance, or click another day to pin it."
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
                    overview(detail)
                } else {
                    Text("Nothing recorded on this day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onOpenInsights {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    Button {
                        onOpenInsights(day.date)
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Text("Open in Insights")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Open the full report for this day")
                    .padding(Theme.Space.m)
                }
                .background(Theme.background)
            }
        }
    }

    private func overview(_ detail: DayDetail) -> some View {
        let extra = model.selectedOverview
        let sessions = extra?.totals?.sessions
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(Self.friendlyDate(detail.date))
                .font(.system(size: 15, weight: .semibold))

            Stat(
                label: "Value at list rates",
                value: detail.value.formatted,
                note: detail.estimated ? "estimated" : "not billed",
                tint: Theme.accent,
                size: 22
            )

            Text(headline(detail, sessions: sessions))
                .font(.caption)
                .foregroundStyle(.secondary)

            counters(detail)

            split(detail)

            groupCard(
                title: "Models",
                subtitle: "List-rate value",
                rows: pricedModelRows(detail, extra: extra),
                showsValue: true,
                isHarness: false
            )

            groupCard(
                title: "Harnesses",
                subtitle: "Which agent produced the tokens",
                rows: harnessRows(detail, extra: extra),
                showsValue: false,
                isHarness: true
            )

            if let projects = extra?.byProject, !projects.isEmpty {
                groupCard(
                    title: "Projects",
                    subtitle: "Where the work happened",
                    rows: projects.map { bucketRow($0, display: $0.key, monospaced: true) },
                    showsValue: false,
                    isHarness: false
                )
            }

            if let sessions = extra?.bySession, !sessions.isEmpty {
                groupCard(
                    title: "Sessions",
                    subtitle: "This device",
                    rows: sessions.map { bucketRow($0, display: $0.key, monospaced: true) },
                    showsValue: false,
                    isHarness: false
                )
            }

            if !detail.unpricedModels.isEmpty {
                groupCard(
                    title: "Unpriced / local models",
                    subtitle: "No list rate. Tokens still counted.",
                    rows: unpricedModelRows(detail, extra: extra),
                    showsValue: false,
                    isHarness: false
                )
            }

            if model.isLoadingSelectedOverview {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.mini)
                    Text("Loading breakdown…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func headline(_ detail: DayDetail, sessions: UInt64?) -> String {
        var parts = [
            "\(formatTokens(detail.tokens)) tokens",
            "\(detail.events.formatted(.number)) requests",
        ]
        if let sessions {
            parts.append("\(sessions.formatted(.number)) sessions")
        }
        return parts.joined(separator: " · ")
    }

    private func counters(_ detail: DayDetail) -> some View {
        let sums = Self.sumCounters(detail.rows)
        return VStack(spacing: Theme.Space.xs) {
            counterRow("Fresh input", sums.fresh)
            counterRow("Cache read", sums.cacheRead)
            counterRow("Cache write 5m", sums.cacheWrite5m)
            counterRow("Cache write 1h", sums.cacheWrite1h)
            counterRow("Output", sums.output)
        }
    }

    private func counterRow(_ label: String, _ value: UInt64?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.map { formatTokens($0) } ?? "n/a")
                .font(Theme.numeric(11))
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
    }

    private func groupCard(
        title: String,
        subtitle: String,
        rows: [DayGroupRow],
        showsValue: Bool,
        isHarness: Bool
    ) -> some View {
        Card(title: title, subtitle: subtitle, mark: isHarness ? "mark_automation" : "mark_insights") {
            if rows.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(rows.prefix(listLimit)) { row in
                        HStack(spacing: Theme.Space.s) {
                            if isHarness {
                                HarnessMark(id: row.key, size: 15)
                            }
                            Text(row.label)
                                .font(row.monospaced ? Theme.mono(12) : .system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatTokens(row.tokens))
                                .font(Theme.numeric(11))
                                .foregroundStyle(.secondary)
                            if showsValue, let value = row.value {
                                Text(value)
                                    .font(Theme.numeric(11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if rows.count > listLimit {
                        Text("and \(rows.count - listLimit) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func modelRows(_ detail: DayDetail, extra: DayOverview?) -> [DayGroupRow] {
        if let extra, !extra.byModel.isEmpty {
            return extra.byModel.map {
                bucketRow($0, display: shortModel($0.key), monospaced: true)
            }
        }
        return fold(detail.rows, key: { $0.model }, display: shortModel, monospaced: true)
    }

    /// Models that have a list rate. Unpriced and local ones belong in
    /// their own card, not mixed into a column that shows money.
    private func pricedModelRows(_ detail: DayDetail, extra: DayOverview?) -> [DayGroupRow] {
        modelRows(detail, extra: extra).filter { !isUnpriced($0, in: detail) }
    }

    private func unpricedModelRows(_ detail: DayDetail, extra: DayOverview?) -> [DayGroupRow] {
        let priced = modelRows(detail, extra: extra)
        return detail.unpricedModels.map { name in
            if let row = priced.first(where: { matchesUnpriced($0, name: name) }) {
                return DayGroupRow(
                    key: name,
                    label: row.label,
                    tokens: row.tokens,
                    value: nil,
                    monospaced: true
                )
            }
            return DayGroupRow(
                key: name,
                label: shortModel(name).isEmpty ? name : shortModel(name),
                tokens: detail.rows.filter { $0.model == name }.reduce(0) { $0 + $1.tokens },
                value: nil,
                monospaced: true
            )
        }
    }

    private func isUnpriced(_ row: DayGroupRow, in detail: DayDetail) -> Bool {
        detail.unpricedModels.contains { matchesUnpriced(row, name: $0) }
    }

    private func matchesUnpriced(_ row: DayGroupRow, name: String) -> Bool {
        row.key == name || row.label == name || row.label == shortModel(name)
    }

    private func harnessRows(_ detail: DayDetail, extra: DayOverview?) -> [DayGroupRow] {
        if let extra, !extra.bySource.isEmpty {
            return extra.bySource.map {
                bucketRow($0, display: harnessName($0.key), monospaced: false)
            }
        }
        return fold(detail.rows, key: { harnessToolKey($0.src) }, display: harnessName, monospaced: false)
    }

    private func bucketRow(_ bucket: Bucket, display: String, monospaced: Bool) -> DayGroupRow {
        DayGroupRow(
            key: bucket.key,
            label: display.isEmpty ? "unknown" : display,
            tokens: bucket.counters.total,
            value: bucket.value.formatted,
            monospaced: monospaced
        )
    }

    private func fold(
        _ parts: [DayPart],
        key: (DayPart) -> String,
        display: (String) -> String,
        monospaced: Bool
    ) -> [DayGroupRow] {
        var totals: [(String, UInt64)] = []
        var index: [String: Int] = [:]
        for part in parts {
            let raw = key(part)
            if let i = index[raw] {
                totals[i].1 += part.tokens
            } else {
                index[raw] = totals.count
                totals.append((raw, part.tokens))
            }
        }
        totals.sort { $0.1 > $1.1 }
        return totals.map { raw, tokens in
            DayGroupRow(
                key: raw,
                label: display(raw).isEmpty ? "unknown" : display(raw),
                tokens: tokens,
                value: nil,
                monospaced: monospaced
            )
        }
    }

    private static func sumCounters(_ rows: [DayPart]) -> (
        fresh: UInt64?, cacheRead: UInt64?, cacheWrite5m: UInt64?,
        cacheWrite1h: UInt64?, output: UInt64?
    ) {
        func fold(_ pick: (DayPart) -> UInt64?) -> UInt64? {
            let values = rows.compactMap(pick)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +)
        }
        return (
            fold(\.fresh),
            fold(\.cacheRead),
            fold(\.cacheWrite5m),
            fold(\.cacheWrite1h),
            fold(\.output)
        )
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
        let utc = TimeZone(secondsFromGMT: 0)
        parse.timeZone = utc
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale.current
        out.timeZone = utc
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }
}

private struct DayGroupRow: Identifiable {
    var key: String
    var label: String
    var tokens: UInt64
    var value: String?
    var monospaced: Bool

    var id: String { key }
}
