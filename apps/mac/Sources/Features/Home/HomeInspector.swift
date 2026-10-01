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
                InspectorTitle(title: L10n.text("apple.homeinspector.day.8f2364e1"), symbol: "calendar")
                Spacer(minLength: 0)
            }
            Group {
                if let day = model.selectedDay {
                    dayBody(day)
                } else {
                    InspectorEmptyState(
                        mark: "mark_activity",
                        title: L10n.text("apple.homeinspector.today_opens_here.a6818424"),
                        subtitle: L10n.text("apple.homeinspector.the_heatmap_is_still_loading_hover_a_day_f.566fb595")
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
                    Text(L10n.text("apple.homeinspector.this_day_is_outside_the_unlocked_window.0d92dfdb"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                } else if model.isLoadingSelectedDetail, model.selectedDetail == nil {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("apple.homeinspector.loading_day.758e26f6"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let detail = model.selectedDetail {
                    overview(detail)
                } else {
                    Text(L10n.text("apple.homeinspector.nothing_recorded_on_this_day.5ad77ba8"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A footer bar, not a button that happens to be last.
        //
        // It used to be a full-width secondary button on the same background
        // as the content, under a hairline, with content-sized padding all
        // round. Three things read as one stranded slab: the rule separated
        // nothing because both sides were the same colour, the border was the
        // only edge and it is faint by design, and the padding was the
        // content's rather than a bar's. Now the bar carries the sidebar
        // surface, which is what every other footer in the app stands on, and
        // the action is the accent, because opening the day is the reason this
        // panel has a footer at all.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onOpenInsights {
                VStack(spacing: 0) {
                    ThemeRule()
                    Button {
                        onOpenInsights(day.date)
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Text(L10n.text("apple.homeinspector.open_in_insights.5529d386"))
                            Image(systemName: "arrow.right")
                                .font(Theme.font(11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle())
                    .help(L10n.text("apple.homeinspector.open_the_full_report_for_this_day.d8b6ca88"))
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                }
                .background(Theme.sidebar)
            }
        }
    }

    private func overview(_ detail: DayDetail) -> some View {
        let extra = model.selectedOverview
        let sessions = extra?.totals?.sessions
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(Self.friendlyDate(detail.date))
                .font(Theme.font(15, weight: .semibold))

            Stat(
                label: L10n.text("apple.homeinspector.api_list_price.060458ef"),
                value: detail.value.formatted,
                note: detail.estimated ? "estimated" : L10n.text("apple.homeinspector.not_an_extra_bill.79d2c7ad"),
                tint: Theme.accent,
                size: 22
            )

            Text(headline(detail, sessions: sessions))
                .font(Theme.caption)
                .foregroundStyle(.secondary)

            counters(detail)

            split(detail)

            groupCard(
                title: L10n.text("apple.homeinspector.models.d17d2d78"),
                subtitle: L10n.text("apple.homeinspector.api_list_price.060458ef"),
                rows: pricedModelRows(detail, extra: extra),
                showsValue: true,
                isHarness: false
            )

            groupCard(
                title: L10n.text("apple.homeinspector.coding_tools.6032f740"),
                subtitle: L10n.text("apple.homeinspector.which_agent_produced_the_tokens.d4a409e3"),
                rows: harnessRows(detail, extra: extra),
                showsValue: false,
                isHarness: true
            )

            if let projects = extra?.byProject, !projects.isEmpty {
                groupCard(
                    title: L10n.text("common.projects"),
                    subtitle: L10n.text("apple.homeinspector.where_the_work_happened.250180a6"),
                    rows: projects.map { bucketRow($0, display: $0.key, monospaced: true) },
                    showsValue: false,
                    isHarness: false
                )
            }

            if let sessions = extra?.bySession, !sessions.isEmpty {
                groupCard(
                    title: L10n.text("apple.homeinspector.sessions.6fa3cbf4"),
                    subtitle: L10n.text("apple.homeinspector.this_device.d052579c"),
                    rows: sessions.map { bucketRow($0, display: $0.key, monospaced: true) },
                    showsValue: false,
                    isHarness: false
                )
            }

            if !detail.unpricedModels.isEmpty {
                groupCard(
                    title: L10n.text("apple.homeinspector.unpriced_local_models.620f0ccf"),
                    subtitle: L10n.text("apple.homeinspector.no_api_price_tokens_still_counted.9fd4e18e"),
                    rows: unpricedModelRows(detail, extra: extra),
                    showsValue: false,
                    isHarness: false
                )
            }

            if model.isLoadingSelectedOverview {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("apple.homeinspector.loading_breakdown.98c86f22"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func headline(_ detail: DayDetail, sessions: UInt64?) -> String {
        var parts = [
            L10n.text("apple.homeinspector.0_tokens.624f11b9", "\(formatTokens(detail.tokens))"),
            L10n.text("apple.homeinspector.0_requests.26f9894c", "\(detail.events.formatted(.number))"),
        ]
        if let sessions {
            parts.append(L10n.text("apple.homeinspector.0_sessions.42cfea31", "\(sessions.formatted(.number))"))
        }
        return parts.joined(separator: " · ")
    }

    private func counters(_ detail: DayDetail) -> some View {
        let sums = Self.sumCounters(detail.rows)
        return VStack(spacing: Theme.Space.xs) {
            counterRow(L10n.text("apple.homeinspector.fresh_input.a5156480"), sums.fresh)
            counterRow(L10n.text("apple.homeinspector.cache_read.0008ce30"), sums.cacheRead)
            counterRow(L10n.text("apple.homeinspector.cache_write_5m.bf7e82f8"), sums.cacheWrite5m)
            counterRow(L10n.text("apple.homeinspector.cache_write_1h.80055f01"), sums.cacheWrite1h)
            counterRow(L10n.text("apple.homeinspector.output.b2439bcb"), sums.output)
        }
    }

    private func counterRow(_ label: String, _ value: UInt64?) -> some View {
        HStack {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.map { formatTokens($0) } ?? L10n.text("apple.homeinspector.n_a.a683c5c5"))
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
                Text(L10n.text("apple.homeinspector.nothing_recorded_yet.17f000e0"))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(rows.prefix(listLimit)) { row in
                        HStack(spacing: Theme.Space.s) {
                            if isHarness {
                                HarnessMark(id: row.key, size: 15)
                            }
                            Text(row.label)
                                .font(row.monospaced ? Theme.mono(12) : Theme.font(12))
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
                        Text(L10n.text("apple.homeinspector.and_0_more.938c3a14", "\(rows.count - listLimit)"))
                            .font(Theme.caption)
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
                tokens: detail.rows.filter { $0.model == name }.reduce(UInt64(0)) { $0.saturatingAdd($1.tokens) },
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
            label: display.isEmpty ? L10n.text("apple.homeinspector.unknown.b23a6a84") : display,
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
                totals[i].1 = totals[i].1.saturatingAdd(part.tokens)
            } else {
                index[raw] = totals.count
                totals.append((raw, part.tokens))
            }
        }
        totals.sort { $0.1 > $1.1 }
        return totals.map { raw, tokens in
            DayGroupRow(
                key: raw,
                label: display(raw).isEmpty ? L10n.text("apple.homeinspector.unknown.b23a6a84") : display(raw),
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
            return values.reduce(UInt64(0)) { $0.saturatingAdd($1) }
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
            acc.fresh = acc.fresh.saturatingAdd(part.fresh ?? 0)
            acc.cacheRead = acc.cacheRead.saturatingAdd(part.cacheRead ?? 0)
            acc.cacheWrite = acc.cacheWrite.saturatingAdd(
                (part.cacheWrite5m ?? 0).saturatingAdd(part.cacheWrite1h ?? 0)
            )
            acc.output = acc.output.saturatingAdd(part.output ?? 0)
        }
        let grand = total.fresh.saturatingAdd(total.cacheRead)
            .saturatingAdd(total.cacheWrite)
            .saturatingAdd(total.output)
        guard grand > 0 else { return AnyView(EmptyView()) }

        let segments: [(label: String, value: UInt64, color: Color)] = [
            (L10n.text("apple.homeinspector.cache_read.e16dda7a"), total.cacheRead, Theme.heat[1]),
            (L10n.text("apple.homeinspector.cache_write.e2bcc9d6"), total.cacheWrite, Theme.heat[2]),
            ("output", total.output, Theme.heat[4]),
            (L10n.text("apple.homeinspector.fresh_in.28475ebb"), total.fresh, Theme.accent),
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
                        .font(Theme.font(11))
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
