// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
import Charts

#if !os(macOS)

struct ClientInsightsView: View {
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientInsightsModel.self) private var model
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                cutPicker
                content
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await ClientRefresh.pull("insights") { await model.refresh() }
        }
        // On iOS 26 this lands in the bottom bar beside the tabs, which is the
        // half of the screen a thumb reaches. Long model identifiers are
        // exactly the thing worth filtering.
        .searchable(text: $search, prompt: L10n.text("apple.clientinsightsview.filter_0.50ee55cd", "\(model.cut.plural)"))
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await model.refresh() }
        }
    }


    private var cutPicker: some View {
        @Bindable var model = model
        return SegmentedTabs(
            options: ClientInsightsModel.Cut.allCases,
            selection: $model.cut
        ) { $0.label }
        .onChange(of: model.cut) { _, _ in
            Task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let rows = model.rows(for: model.cut) {
            if rows.isEmpty {
                ClientEmptyState(
                    kind: .nothingYet,
                    title: L10n.text("apple.clientinsightsview.nothing_recorded_yet.cb77e288"),
                    message: L10n.text("apple.clientinsightsview.add_a_computer_to_this_account_and_what_it.1769a0a7"),
                    actionTitle: L10n.text("apple.clientinsightsview.how_to_start.69f36336"),
                    actionIcon: .home,
                    action: { navigation.destination = .home },
                    art: .firstBars
                )
            } else {
                summary(rows)
                let shown = filtered(rows)
                if model.cut == .day && !shown.isEmpty {
                    let days = shown.sorted { $0.key < $1.key }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ClientSectionTitle(title: L10n.text("apple.clientinsightsview.daily_activity.561d7c9e"), mark: "mark_activity")
                        Text(L10n.text("apple.clientinsightsview.tokens_per_day_cache_included.a6ebc86d")).font(ClientType.caption).foregroundStyle(.secondary)
                        Chart(days) { day in
                            if let position = InsightDayAxis.position(day.key) {
                                RectangleMark(xStart: .value(L10n.text("apple.clientinsightsview.day.8f2364e1"), position - 0.4), xEnd: .value(L10n.text("apple.clientinsightsview.day.8f2364e1"), position + 0.4),
                                        yStart: .value(L10n.text("apple.clientinsightsview.tokens.a039dfb9"), UInt64(0)), yEnd: .value(L10n.text("apple.clientinsightsview.tokens.a039dfb9"), day.counters.total))
                                    .foregroundStyle(Theme.accent.gradient)
                                    .cornerRadius(3)
                                    .accessibilityLabel(day.key)
                                    .accessibilityValue(L10n.text("apple.clientinsightsview.0_tokens.624f11b9", "\(formatTokens(day.counters.total))"))
                            }
                        }
                        .chartXScale(domain: InsightDayAxis.domain(days.map(\.key)))
                        .chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine().foregroundStyle(Theme.border)
                                AxisValueLabel {
                                    if let tokens = value.as(Double.self) {
                                        Text(formatTokens(InsightDayAxis.tokenCount(tokens))).font(ClientType.caption)
                                    }
                                }
                            }
                        }
                        .frame(height: 180)
                        HStack {
                            Text(days.first.map { model.cut.title(for: $0.key) } ?? "")
                            Spacer()
                            Text(days.last.map { model.cut.title(for: $0.key) } ?? "")
                        }.font(ClientType.caption).foregroundStyle(.secondary)
                    }.padding(Theme.Space.m).cardSurface()
                }
                if model.cut != .day && !shown.isEmpty { tokenChart(shown) }
                if shown.isEmpty {
                    Text(L10n.text("apple.clientinsightsview.nothing_matches_0.d59cf718", "\(search)"))
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Space.s)
                } else {
                    let peak = shown.map(\.valueMicros).max() ?? 1
                    ClientSectionTitle(title: model.cut.label, mark: "mark_insights")
                    ClientAdaptiveCards {
                    ForEach(shown) { row in
                        InsightRow(row: row, cut: model.cut, peak: peak)
                    }
                    }
                }
            }
        } else if model.isLoading {
            ClientWireframe.Page()
        } else if let message = model.errorMessage {
            ClientEmptyState(
                kind: model.needsSignIn ? .needsAccount : .unreachable,
                title: connectivity.isOffline ? L10n.text("apple.clientinsightsview.you_are_offline.4d5c9439") : L10n.text("apple.clientinsightsview.could_not_load_your_usage.45467004"),
                message: connectivity.isOffline
                    ? L10n.text("apple.clientinsightsview.this_updates_by_itself_when_the_connection.afd97997")
                    : FriendlyError.from(message).message,
                actionTitle: connectivity.isOffline ? nil : L10n.text("apple.clientinsightsview.try_again.d8b8392e"),
                actionIcon: .refresh,
                action: connectivity.isOffline ? nil : { Task { await model.refresh() } }
            )
        }
    }

    private func summary(_ rows: [Bucket]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ClientSectionTitle(title: L10n.text("apple.clientinsightsview.this_period.8ed3e11f"), mark: "mark_insights")
                .padding(.bottom, 4)
            Text(rows.totalValue.formatted)
                .font(ClientType.figure)
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(L10n.text("apple.clientinsightsview.at_api_list_price_across_every_device.956db3fc"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            ClientStatPanels(panels: ClientInsightFacts.panels(
                tokens: rows.reduce(0) { $0.saturatingAdd($1.counters.total) },
                events: rows.reduce(0) { $0.saturatingAdd($1.events) },
                count: rows.count,
                countLabel: model.cut.label,
                formatCompact: formatTokens
            )).padding(.top, Theme.Space.s)
            if let age = model.ageDescription {
                Text(age)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func tokenChart(_ rows: [Bucket]) -> some View {
        let ranked = Array(rows.sorted { $0.counters.total > $1.counters.total }.prefix(8))
        let peak = max(1, ranked.map(\.counters.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: L10n.text("apple.clientinsightsview.most_used_0.ad293687", "\(model.cut.plural)"), mark: "mark_insights")
            Text(L10n.text("apple.clientinsightsview.tokens_including_reported_cache_usage.a3e0a451"))
                .font(ClientType.caption).foregroundStyle(.secondary)
            ForEach(ranked) { row in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack {
                        Text(model.cut.title(for: row.key)).lineLimit(1)
                        Spacer(minLength: Theme.Space.s)
                        Text(formatTokens(row.counters.total)).foregroundStyle(.secondary)
                    }.font(ClientType.caption)
                    ProgressView(value: Double(row.counters.total), total: Double(peak))
                        .tint(Theme.accent)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.cut.title(for: row.key))
                .accessibilityValue(L10n.text("apple.clientinsightsview.0_tokens.624f11b9", "\(formatTokens(row.counters.total))"))
            }
        }
        .padding(Theme.Space.m).cardSurface()
    }

    private func filtered(_ rows: [Bucket]) -> [Bucket] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return rows }
        return rows.filter { row in
            row.key.lowercased().contains(term)
                || model.cut.title(for: row.key).lowercased().contains(term)
        }
    }
}

private struct InsightRow: View {
    let row: Bucket
    let cut: ClientInsightsModel.Cut
    let peak: Int64

    private var share: Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, Double(row.valueMicros) / Double(peak)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                if cut == .source {
                    HarnessMark(id: row.key, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(cut.title(for: row.key))
                        .font(ClientType.label.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L10n.text("apple.clientinsightsview.0_tokens_1_events.8b30d61d", "\(formatTokens(row.counters.total))", "\(row.events.formatted())"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.s)
                Text(row.value.formatted)
                    .font(ClientType.rowFigure)
                    .foregroundStyle(Theme.accent)
            }
            // The bar is a comparison, not a second copy of the number, so it
            // carries no label of its own and is hidden from VoiceOver: the
            // figure beside it already says the amount.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.accent.opacity(0.12))
                    Capsule()
                        .fill(Theme.accent.opacity(0.55))
                        .frame(width: max(2, geo.size.width * share))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(Theme.Space.s)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.text("apple.clientinsightsview.0_1_at_api_list_price_2_tokens.a64f3739", "\(cut.title(for: row.key))", "\(row.value.formatted)", "\(formatTokens(row.counters.total))")
        )
    }
}

#endif
