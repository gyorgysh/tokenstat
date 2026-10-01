// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Charts
import SwiftUI

struct InsightsView: View {
    @Bindable var model: InsightsModel
    @AppStorage("activity.scope") private var scope: ActivityScope = .allMachines
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Leave a day-focused view and return to Home, which is where it came
    /// from. Nil when Insights was opened directly, so there is no back arrow
    /// for a journey nobody took.
    var accountIdentity: String = ""
    var onBackToHome: (() -> Void)?

    private var tabs: [(tab: InsightsModel.Tab, label: String, symbol: String)] {
        InsightsModel.Tab.allCases.map { ($0, $0.label, $0.symbol) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Same chrome row as Home: toggles (from RootView) left, actions
            // right. Tabs are a full-width strip under that row.
            DetailChromeBar(
                leading: {
                    // Back first, where a hand goes to leave. The device
                    // picker sits after the sidebar toggle, the way Home
                    // draws the same picker.
                    if model.focusedDay != nil && scope == .thisMachine {
                        ToolbarIconButton(
                            systemImage: "chevron.left",
                            help: L10n.text("apple.insightsview.back_to_home.eec78426")
                        ) {
                            onBackToHome?()
                        }
                    }
                },
                accessory: {
                    SegmentedCapsulePicker(
                        options: ActivityScope.allCases.map { (value: $0, label: $0.label, symbol: $0.symbol) },
                        selection: $scope
                    ).frame(width: 280)
                },
                trailing: {
                    if scope == .thisMachine {
                    SegmentedCapsulePicker(
                        options: InsightsModel.Period.allCases.map {
                            (value: $0, label: L10n.enumLabel($0), symbol: "")
                        },
                        selection: $model.period
                    )
                    .frame(maxWidth: 240)
                    .help(L10n.text("apple.insightsview.report_period.2447b4ac"))
                    ToolbarIconButton(
                        systemImage: "arrow.triangle.2.circlepath",
                        help: L10n.text("apple.insightsview.read_new_sessions_from_supported_local_too.baa5d296"),
                        isBusy: model.isScanning,
                        isEnabled: !model.isScanning && model.scanCooldownUntil == nil
                    ) {
                        Task {
                            LogoRefresh.began()
                            await model.scan()
                        }
                    }
                    ToolbarIconButton(
                        systemImage: "arrow.down.circle",
                        help: L10n.text("apple.insightsview.fetch_usage_from_remote_vendors_such_as_cu.406af0cd"),
                        isBusy: model.isFetching,
                        isEnabled: !model.isFetching && model.fetchCooldownUntil == nil
                    ) {
                        Task {
                            LogoRefresh.began()
                            await model.fetchRemotes()
                        }
                    }
                    }
                }
            )
            if scope == .allMachines {
                AccountInsightsContent().id(accountIdentity)
            } else {
                TabStrip(tabs: tabs, selection: $model.tab)
                content
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.actionMessage, severity: .success)
                .padding(Theme.Space.l)
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }
                // A day arrived from Home's heatmap. It has to be visible and
                // dismissable, or every figure on the screen is quietly about
                // one day and the period control says otherwise.
                if let day = model.focusedDay {
                    HStack(spacing: Theme.Space.s) {
                        Label(day, systemImage: "calendar")
                            .font(Theme.callout)
                        Spacer()
                        Button(L10n.text("apple.insightsview.clear.83b12c22"), .dismiss) { model.clearFocusedDay() }
                            .buttonStyle(.plain)
                            .font(Theme.callout.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                }

                if isWarming {
                    // The shape of the screen that is coming, not a spinner in
                    // the middle of an empty pane. The report is a chart over
                    // three lists, and saying so while it loads is more use
                    // than saying "wait".
                    placeholder
                } else {
                    switch model.tab {
                    case .overview:
                        overview
                            .transition(.smoothIn(reduceMotion: reduceMotion))
                    case .models, .projects, .harnesses, .sessions:
                        BreakdownTable(
                            rows: model.rows,
                            selected: $model.selected,
                            showsValue: model.tab == .models,
                            // A session id or a project path is read character
                            // by character. A harness has a name, not an id.
                            monospaced: model.tab != .harnesses,
                            isHarness: model.tab == .harnesses
                        )
                        // A fresh page window per breakdown and per period.
                        // Without the id the table is the same view across
                        // tabs, so "showing 80 of 3000 sessions" would carry
                        // over to a models list with nine rows in it.
                        .id("\(model.tab.rawValue)-\(model.period.rawValue)")
                        .transition(.smoothIn(reduceMotion: reduceMotion))
                    }
                }
            }
            .padding(Theme.Space.m)
            .animation(.easeOut(duration: 0.18), value: isWarming)
        }
    }

    /// Waiting on the first report of the session.
    ///
    /// Only the first. A period change re-reads the archive with the whole
    /// screen already drawn, and blanking it out to redraw the same layout
    /// makes a fast query look slower than it is.
    private var isWarming: Bool {
        model.isLoading && model.totals == nil && model.errorMessage == nil
    }

    /// The overview's layout in grey: the daily chart, then the row of lists.
    private var placeholder: some View {
        // Sharp wireframe of the overview. Real content replaces it with
        // `.smoothIn` when the first report lands; no blur veil.
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Card(title: L10n.text("apple.insightsview.usage_over_time.56d901b0"), subtitle: L10n.text("apple.insightsview.daily_tokens_cache_included.57801e52"), mark: "mark_insights") {
                Skeleton.Bar(width: nil, height: 260)
            }
            WidthReader { width in
                skeletonTriple(width: width)
            }
        }
        .transition(.opacity)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let totals = model.totals {
                WidthReader { width in
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: width >= 760 ? 4 : (width >= 380 ? 2 : 1)), spacing: 12) {
                    InsightMetric(title: L10n.text("apple.insightsview.total_tokens.e7601ca1"), value: formatTokens(totals.counters.total),
                                  detail: L10n.text("apple.insightsview.including_reported_cache_usage.44e4a309"), symbol: "chart.bar.fill")
                    InsightMetric(title: L10n.text("apple.insightsview.api_list_price.060458ef"), value: model.periodValue.formatted,
                                  detail: L10n.text("apple.insightsview.not_an_extra_bill.ed03e1c3"), symbol: "dollarsign.circle")
                        .help(L10n.text("apple.insightsview.dollar_amounts_are_the_published_api_price.0275eb31"))
                    InsightMetric(title: L10n.text("apple.insightsview.sessions.6fa3cbf4"), value: totals.sessions.formatted(),
                                  detail: L10n.text("apple.insightsview.0_recorded_events.1b95ec0e", "\(totals.events.formatted())"), symbol: "bubble.left.and.bubble.right")
                    InsightMetric(title: L10n.text("apple.insightsview.active_days.6cbebfa2"), value: totals.days.formatted(),
                                  detail: L10n.text("apple.insightsview.0_tokens_active_day.a9bff644", "\(formatTokens(totals.days > 0 ? totals.counters.total / totals.days : 0))"), symbol: "calendar")
                }
                }
            }
            Card(title: L10n.text("apple.insightsview.usage_over_time.56d901b0"), subtitle: L10n.text("apple.insightsview.daily_tokens_cache_included.57801e52"), mark: "mark_insights") {
                DailyChart(rows: model.daily)
                HStack {
                    if let peak = model.daily.max(by: { $0.counters.total < $1.counters.total }) {
                        Label(L10n.text("apple.insightsview.peak_0_1.cb480974", "\(formatTokens(peak.counters.total))", "\(peak.key)"), systemImage: "arrow.up.right")
                    }
                    Spacer()
                    Text(L10n.text("apple.insightsview.0_recorded_days.81103b2c", "\(model.daily.count)"))
                }
                .font(Theme.caption).foregroundStyle(.secondary)
            }
            WidthReader { width in
                if width >= 680 {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        rankingCard(title: L10n.text("apple.insightsview.top_models.79489561"), rows: model.byModel, tab: .models)
                        rankingCard(title: L10n.text("apple.insightsview.by_coding_tool.d88bafe1"), rows: model.bySource, tab: .harnesses)
                    }.fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: Theme.Space.m) {
                        rankingCard(title: L10n.text("apple.insightsview.top_models.79489561"), rows: model.byModel, tab: .models)
                        rankingCard(title: L10n.text("apple.insightsview.by_coding_tool.d88bafe1"), rows: model.bySource, tab: .harnesses)
                    }
                }
            }
            if !model.byProject.isEmpty {
                rankingCard(title: L10n.text("apple.insightsview.project_activity.3601328f"), rows: model.byProject, tab: .projects)
            }
        }
    }

    private func rankingCard(title: String, rows: [Bucket], tab: InsightsModel.Tab) -> some View {
        Card(title: title, subtitle: L10n.text("apple.insightsview.ranked_by_tokens_share_of_this_breakdown.929721dd"), mark: tab == .harnesses ? "mark_automation" : "mark_insights",
             accessory: AnyView(Button(L10n.text("apple.insightsview.view_all_0.41a41832", "\(rows.count)"), .more) { model.tab = tab }
                .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.accent)), fillsHeight: true) {
            InsightRanking(rows: rows, isHarness: tab == .harnesses, showsValue: tab == .models) { row in
                model.tab = tab
                model.selected = row
            }
        }
    }

    /// The grey loading version of the same reflow.
    @ViewBuilder
    private func skeletonTriple(width: CGFloat) -> some View {
        if width >= .threeAcrossWidth {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Skeleton.CardPlaceholder(rows: 5)
                Skeleton.CardPlaceholder(rows: 5)
                Skeleton.CardPlaceholder(rows: 5)
            }
        } else if width >= .twoColumnWidth {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Skeleton.CardPlaceholder(rows: 5)
                    Skeleton.CardPlaceholder(rows: 5)
                }
                Skeleton.CardPlaceholder(rows: 5)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Skeleton.CardPlaceholder(rows: 5)
                Skeleton.CardPlaceholder(rows: 5)
                Skeleton.CardPlaceholder(rows: 5)
            }
        }
    }

}

// MARK: - Table

/// The full breakdown for a tab. No sort controls: the archive already returns
/// rows largest first, which is the order anyone wants.
private struct BreakdownTable: View {
    var rows: [Bucket]
    @Binding var selected: Bucket?
    var showsValue: Bool
    var monospaced: Bool
    var isHarness: Bool = false

    /// How many rows the table draws before the reveal button.
    ///
    /// An archive holds every session that ever ran, and by the second month
    /// that is thousands of them. SwiftUI builds a `VStack`'s children all at
    /// once, so the whole list was laid out on every hover and the window went
    /// unresponsive on the Sessions tab. Page it. The first page is deep
    /// enough that models, projects and harnesses never reach the button.
    private static let firstPage = 50
    /// Rows added per press of the reveal button.
    private static let pageStep = 30

    @State private var visible = BreakdownTable.firstPage

    /// The rows actually drawn.
    private var page: ArraySlice<Bucket> { rows.prefix(visible) }

    private var hidden: Int { max(0, rows.count - visible) }

    var body: some View {
        if rows.isEmpty {
            EmptyHint(
                symbol: "tray",
                title: L10n.text("apple.insightsview.nothing_recorded.44985e2c"),
                text: L10n.text("apple.insightsview.no_usage_landed_in_this_period_scan_or_wid.59209497")
            )
        } else {
            VStack(spacing: 0) {
                header
                ForEach(page) { row in
                    BreakdownRow(
                        row: row,
                        share: share(row),
                        showsValue: showsValue,
                        monospaced: monospaced,
                        isSelected: selected?.key == row.key,
                        isHarness: isHarness
                    )
                    .contentShape(.rect)
                    .onTapGesture { selected = selected?.key == row.key ? nil : row }
                    ThemeRule().opacity(0.3)
                }
                if hidden > 0 {
                    revealMore
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    /// The footer that hands out the next page.
    ///
    /// Two choices on purpose. The step is the one to press, and "Show all" is
    /// there for the rare read of a whole archive, with its cost written on it
    /// rather than hidden behind a scroll that never ends.
    private var revealMore: some View {
        HStack(spacing: Theme.Space.m) {
            Button(L10n.text("apple.insightsview.show_0_more.b91c3640", "\(min(Self.pageStep, hidden))"), .more) {
                visible += Self.pageStep
            }
            .buttonStyle(.plain)
            .font(Theme.callout.weight(.medium))
            .foregroundStyle(Theme.accent)

            Text(L10n.text("apple.insightsview.0_more_hidden.4beb56b2", "\(hidden)"))
                .font(Theme.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button(L10n.text("apple.insightsview.show_all.2150d8df"), .more) { visible = rows.count }
                .buttonStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .help(L10n.text("apple.insightsview.draws_every_remaining_row_a_long_list_take.db76817f"))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Text(L10n.text("apple.insightsview.name.eaa58932")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text("apple.insightsview.sessions.3068f7e5")).frame(width: 66, alignment: .trailing)
            Text(L10n.text("apple.insightsview.tokens.a0dd5436")).frame(width: 66, alignment: .trailing)
            if showsValue {
                Text(L10n.text("apple.insightsview.value.8ec121c9")).frame(width: 88, alignment: .trailing)
            }
        }
        .font(Theme.sectionHeader)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func share(_ row: Bucket) -> Double {
        let top = Double(rows.first?.counters.total ?? 1)
        return min(1, Double(row.counters.total) / max(1, top))
    }
}

private struct BreakdownRow: View {
    var row: Bucket
    var share: Double
    var showsValue: Bool
    var monospaced: Bool
    var isSelected: Bool
    /// Harness rows carry the tool's mark and its proper name. Every other
    /// dimension is a raw id and stays one.
    var isHarness: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if isHarness {
                HarnessMark(id: row.key, size: 16)
            }
            Text(isHarness ? harnessName(row.key) : (row.key.isEmpty ? L10n.text("apple.insightsview.unknown.b23a6a84") : row.key))
                .font(monospaced ? Theme.mono(12) : Theme.font(13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(row.sessions)")
                .font(Theme.numeric(12))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)

            Text(formatTokens(row.counters.total))
                .font(Theme.numeric(12))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)

            if showsValue {
                Text(row.value.formatted)
                    .font(Theme.numeric(12))
                    .lineLimit(1)
                    .frame(width: 88, alignment: .trailing)
                    .help(L10n.text("apple.insightsview.api_list_price_not_an_extra_bill.7ecc2b1d"))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(isSelected ? Theme.rowHighlight : .clear)
        .overlay(alignment: .bottomLeading) {
            // Share of the largest row, as a hairline along the bottom rather
            // than its own column. The comparison is the point, the exact
            // percentage is not.
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accent.opacity(0.55))
                    .frame(width: geo.size.width * share, height: 1)
                    .offset(y: geo.size.height - 1)
            }
        }
    }
}

private struct InsightMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(Theme.callout).foregroundStyle(.secondary)
            Text(value).font(Theme.numeric(28, weight: .semibold))
                .foregroundStyle(Color.primary).lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct InsightRanking: View {
    let rows: [Bucket]
    let isHarness: Bool
    let showsValue: Bool
    let select: (Bucket) -> Void

    private var total: Double { rows.reduce(0) { $0 + Double($1.counters.total) } }
    private var peak: Double { Double(rows.map(\.counters.total).max() ?? 0) }

    var body: some View {
        if rows.isEmpty {
            EmptyHint(text: L10n.text("apple.insightsview.nothing_recorded_yet.17f000e0"))
        } else {
            VStack(spacing: 14) {
                ForEach(rows.prefix(6)) { row in
                    Button { select(row) } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 8) {
                                if isHarness { HarnessMark(id: row.key, size: 16) }
                                Text(isHarness ? harnessName(row.key) : (row.key.isEmpty ? L10n.text("apple.insightsview.unknown.b23a6a84") : row.key))
                                    .font(isHarness ? Theme.font(13) : Theme.mono(12))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(formatTokens(row.counters.total)).font(Theme.numeric(12, weight: .medium))
                                Text((total > 0 ? Double(row.counters.total) / total : 0).formatted(.percent.precision(.fractionLength(1))))
                                    .font(Theme.numeric(11)).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                            }
                            GeometryReader { geo in
                                Capsule().fill(Theme.accent.opacity(0.08))
                                Capsule().fill(Theme.accent.gradient)
                                    .frame(width: geo.size.width * (peak > 0 ? Double(row.counters.total) / peak : 0))
                            }.frame(height: 5).accessibilityHidden(true)
                            HStack {
                                Text(L10n.text("apple.insightsview.0_sessions.42cfea31", "\(row.sessions.formatted())"))
                                Spacer()
                                if showsValue { Text(L10n.text("apple.insightsview.0_at_api_list_price.1faebace", "\(row.value.formatted)")) }
                            }.font(Theme.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .help(L10n.text("apple.insightsview.inspect_0.0ae7a9ec", "\(row.key)"))
                }
            }
        }
    }
}

private struct DailyChart: View {
    var rows: [Bucket]
    @State private var selectedDay: String?
    @State private var showsValue = false

    /// Every nth day, so labels never collide however long the period is.
    private var labelledDays: [String] {
        guard !rows.isEmpty else { return [] }
        let stride = max(1, Int((Double(rows.count) / 8).rounded(.up)))
        return rows.enumerated()
            .filter { $0.offset % stride == 0 }
            .map(\.element.key)
    }

    /// `2026-07-29` becomes `07-29`. The year is the same on every bar.
    private func shortDay(_ raw: String) -> String {
        raw.count > 5 ? String(raw.suffix(5)) : raw
    }

    /// The row under the pointer, if any.
    private var hoveredRow: Bucket? {
        guard let selectedDay else { return nil }
        return rows.first { $0.key == selectedDay }
    }

    var body: some View {
        if rows.isEmpty {
            EmptyHint(
                symbol: "calendar.badge.exclamationmark",
                title: L10n.text("apple.insightsview.no_usage_in_this_period.ed8918b1"),
                text: L10n.text("apple.insightsview.the_days_you_picked_have_no_events_try_a_w.078db9c9")
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(showsValue ? L10n.text("apple.insightsview.daily_api_list_price_not_an_extra_bill.c12b9c19") : L10n.text("apple.insightsview.daily_token_volume.e3ab0b2f"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(L10n.text("apple.insightsview.chart_metric.0a62bdb0"), selection: $showsValue) {
                    Text(L10n.text("apple.insightsview.tokens.a039dfb9")).tag(false)
                    Text(L10n.text("apple.insightsview.api_list_price.060458ef")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            Chart(rows) { row in
                BarMark(
                    x: .value(L10n.text("apple.insightsview.day.8f2364e1"), row.key),
                    y: .value(L10n.text("apple.insightsview.usage.8d59829c"), showsValue ? Double(row.valueMicros) / 1_000_000 : Double(row.counters.total)),
                    // Capped, not proportional. A categorical axis gives every
                    // bar an equal share of the plot, so filtering to one day
                    // drew a single bar the width of the card: a block, with no
                    // shape to read and nothing to compare it against.
                    width: rows.count > 12 ? .automatic : .fixed(36)
                )
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(2)
                if selectedDay == row.key {
                    RuleMark(x: .value(L10n.text("apple.insightsview.selected_day.eab13a3c"), row.key))
                        .foregroundStyle(Theme.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) {
                            Text(showsValue ? tokens.formatted(.currency(code: "USD").precision(.fractionLength(0))) : formatTokens(UInt64(max(0, tokens)))).font(Theme.caption2)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDay)
            // The hovered day's summary, drawn in the chart's topmost layer.
            // It used to be an annotation on the RuleMark, which rendered
            // behind the bars: the label's material sat under the marks and
            // the text was unreadable. The overlay is composited above
            // everything, and being outside the chart's layout it also cannot
            // rescale the axis the way an annotation could.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let frame = proxy.plotFrame {
                        ForEach(labelledDays, id: \.self) { day in
                            if let x = proxy.position(forX: day) {
                                Text(shortDay(day)).font(Theme.caption2).foregroundStyle(.secondary)
                                    .position(x: geo[frame].minX + x, y: geo[frame].maxY + 12)
                            }
                        }
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame, geo[frame].contains(location) else {
                                    selectedDay = nil
                                    return
                                }
                                selectedDay = proxy.value(atX: location.x - geo[frame].minX, as: String.self)
                            case .ended: selectedDay = nil
                            }
                        }
                    if let row = hoveredRow,
                       let plotFrame = proxy.plotFrame,
                       let x = proxy.position(forX: row.key) {
                        let plot = geo[plotFrame]
                        // `position(forX:)` is relative to the plot area, so
                        // the plot's origin has to come back on. The label is
                        // centred on the bar near the plot's top and clamped
                        // to the chart's edges so it never hangs off.
                        let halfWidth: CGFloat = 58
                        let centerX = min(
                            max(plot.minX + x, plot.minX + halfWidth + 4),
                            max(plot.minX + halfWidth + 4, plot.maxX - halfWidth - 4)
                        )
                        hoverSummary(for: row)
                            .position(x: centerX, y: plot.minY + 30)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 260)
            .padding(.bottom, 20)
            }
        }
    }

    /// The data for the day under the pointer, as a floating chip.
    private func hoverSummary(for row: Bucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shortDay(row.key))
                .font(Theme.caption.weight(.semibold))
            Text(L10n.text("apple.insightsview.0_tokens.624f11b9", "\(formatTokens(row.counters.total))"))
                .font(Theme.caption2)
                .foregroundStyle(.secondary)
            Text(row.value.formatted)
                .help(L10n.text("apple.insightsview.api_list_price_not_an_extra_bill.7ecc2b1d"))
                .font(Theme.numeric(10, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(Theme.Space.s)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Space.s)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .fixedSize()
    }
}

struct EmptyHint: View {
    /// The symbol in the soft accent seat. The app's empty states are drawn in
    /// the brand language, never as a bare system placeholder.
    var symbol: String = "chart.bar.xaxis"
    var title: String = L10n.text("apple.insightsview.nothing_here_yet.49abaf80")
    var text: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 44, height: 44)
                Image(systemName: symbol)
                    .font(Theme.font(18, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(title)
                .font(Theme.callout.weight(.medium))
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
    }
}

/// Account aggregates share the same data contract and cache as the mobile client.
private struct AccountInsightsContent: View {
    @State private var model = ClientInsightsModel()
    @State private var search = ""
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            HStack {
                SegmentedCapsulePicker(
                    options: ClientInsightsModel.Cut.allCases.map { (value: $0, label: $0.label, symbol: "") },
                    selection: $model.cut
                ).frame(maxWidth: 360)
                SearchField(text: $search, prompt: L10n.text("apple.insightsview.filter.638e249f"))
                ToolbarIconButton(systemImage: "arrow.clockwise", help: L10n.text("apple.insightsview.refresh_account_usage.70ac7105"), isBusy: model.isLoading) {
                    Task { await model.refresh() }
                }
            }
            Text(L10n.text("apple.insightsview.synced_usage_across_all_devices_last_53_we.20b8c5e2"))
                .font(Theme.caption).foregroundStyle(.secondary)
            if let error = model.errorMessage { ErrorBanner(message: error) }
            if let age = model.ageDescription { Text(age).font(Theme.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: Theme.Space.s) {
                    if model.isLoading { ProgressView() }
                    if let rows = model.rows(for: model.cut) {
                        let filtered = rows.filter {
                            search.isEmpty || model.cut.title(for: $0.key).localizedStandardContains(search)
                        }
                        if !filtered.isEmpty { usageChart(filtered) }
                        ForEach(filtered.sorted { model.cut == .day ? $0.key > $1.key : $0.valueMicros > $1.valueMicros }) { row in
                            HStack {
                                if model.cut == .source {
                                    HarnessMark(id: row.key, size: 26)
                                }
                                Text(model.cut.title(for: row.key)).lineLimit(1)
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(row.value.formatted).foregroundStyle(Theme.accent)
                                    Text(L10n.text("apple.insightsview.0_tokens.624f11b9", "\(row.counters.total.formatted())")).font(Theme.caption).foregroundStyle(.secondary)
                                }
                            }.padding(Theme.Space.m).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        }
                        if rows.isEmpty { Text(L10n.text("apple.insightsview.no_synced_usage_in_this_period.3484c8af")).foregroundStyle(.secondary) }
                        else if filtered.isEmpty { Text(L10n.text("apple.insightsview.no_matching_usage.8b2c6893")).foregroundStyle(.secondary) }
                    }
                }
            }
        }.padding(Theme.Space.m)
            .task(id: model.cut) { await model.load() }
    }

    private func usageChart(_ rows: [Bucket]) -> some View {
        let daily = model.cut == .day
        let plotted = daily ? rows.sorted { $0.key < $1.key }
            : Array(rows.sorted { $0.counters.total > $1.counters.total }.prefix(8))
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(daily ? L10n.text("apple.insightsview.daily_activity.561d7c9e") : L10n.text("apple.insightsview.most_used_0.ad293687", "\(model.cut.plural)"))
                .font(Theme.headline)
            Text(L10n.text("apple.insightsview.tokens_including_reported_cache_usage.a3e0a451"))
                .font(Theme.caption).foregroundStyle(.secondary)
            if daily {
                Chart(plotted) { row in
                    if let position = InsightDayAxis.position(row.key) {
                        RectangleMark(xStart: .value(L10n.text("apple.insightsview.day.8f2364e1"), position - 0.4), xEnd: .value(L10n.text("apple.insightsview.day.8f2364e1"), position + 0.4),
                                yStart: .value(L10n.text("apple.insightsview.tokens.a039dfb9"), UInt64(0)), yEnd: .value(L10n.text("apple.insightsview.tokens.a039dfb9"), row.counters.total))
                            .foregroundStyle(Theme.accent.gradient)
                            .accessibilityLabel(model.cut.title(for: row.key))
                            .accessibilityValue(L10n.text("apple.insightsview.0_tokens.624f11b9", "\(formatTokens(row.counters.total))"))
                    }
                }
                .chartXScale(domain: InsightDayAxis.domain(plotted.map(\.key)))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel {
                            if let tokens = value.as(Double.self) {
                                Text(formatTokens(InsightDayAxis.tokenCount(tokens))).font(Theme.caption2)
                            }
                        }
                    }
                }
                .frame(height: 170)
                HStack {
                    Text(plotted.first?.key ?? "")
                    Spacer()
                    Text(plotted.last?.key ?? "")
                }.font(Theme.caption).foregroundStyle(.secondary)
            } else {
                Chart(plotted) { row in
                    BarMark(x: .value(L10n.text("apple.insightsview.tokens.a039dfb9"), row.counters.total),
                        y: .value(model.cut.label, model.cut.title(for: row.key)))
                        .foregroundStyle(Theme.accent.gradient)
                        .cornerRadius(3)
                        .accessibilityLabel(model.cut.title(for: row.key))
                        .accessibilityValue(L10n.text("apple.insightsview.0_tokens.624f11b9", "\(formatTokens(row.counters.total))"))
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel {
                            if let tokens = value.as(Double.self) {
                                Text(formatTokens(InsightDayAxis.tokenCount(tokens))).font(Theme.caption2)
                            }
                        }
                    }
                }
                .chartYScale(domain: plotted.map { model.cut.title(for: $0.key) })
                .frame(height: CGFloat(max(1, plotted.count)) * 28 + 24)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

}

struct ScopedInsightsInspector: View {
    @Bindable var model: InsightsModel
    var onClose: () -> Void
    @AppStorage("activity.scope") private var scope: ActivityScope = .allMachines
    var body: some View {
        if scope == .thisMachine {
            InspectorView(model: model, onClose: onClose)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack { Text(L10n.text("apple.insightsview.all_devices.0594fe82")).font(Theme.headline); Spacer(); Button(L10n.text("common.close"), .dismiss, action: onClose) }
                Text(L10n.text("apple.insightsview.aggregated_model_coding_tool_and_daily_usa.c5f79ddb"))
                    .foregroundStyle(.secondary)
                Spacer()
            }.padding(Theme.Space.m)
        }
    }
}
