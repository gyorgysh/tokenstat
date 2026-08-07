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
    /// Leave a day-focused view and return to Home, which is where it came
    /// from. Nil when Insights was opened directly, so there is no back arrow
    /// for a journey nobody took.
    var onBackToHome: (() -> Void)?

    private var tabs: [(tab: InsightsModel.Tab, label: String, symbol: String)] {
        InsightsModel.Tab.allCases.map { ($0, $0.label, $0.symbol) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(tabs: tabs, selection: $model.tab)
            content
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.actionMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .toolbar { toolbar }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let message = model.errorMessage {
                    Banner(text: message, severity: .warning)
                }
                // A day arrived from Home's heatmap. It has to be visible and
                // dismissable, or every figure on the screen is quietly about
                // one day and the period control says otherwise.
                if let day = model.focusedDay {
                    HStack(spacing: Theme.Space.s) {
                        Label(day, systemImage: "calendar")
                            .font(.callout)
                        Spacer()
                        Button("Clear") { model.clearFocusedDay() }
                            .buttonStyle(.plain)
                            .font(.callout.weight(.medium))
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
                    }
                }
            }
            .padding(Theme.Space.m)
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Card(title: "Daily volume", subtitle: "Tokens per day, cache included") {
                Skeleton.Bar(width: nil, height: 160)
            }
            WidthReader { width in
                skeletonTriple(width: width)
            }
        }
        .warming(true)
    }

    private var overview: some View {
        // The plan limit and plan usage cards used to open this screen. They
        // moved to Home: "what is left of the allowance" is asked before the
        // work, not while reading a report about it.
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Card(title: "Daily volume", subtitle: "Tokens per day, cache included") {
                DailyChart(rows: model.daily)
            }

            // Three across once there is room, and never fewer cards than
            // there are lists: below the three-across width the project list
            // moves underneath the pair instead of vanishing, and below the
            // two-across width all three stack.
            WidthReader { width in
                layoutTriple(width: width)
            }
        }
    }

    /// The three breakdown lists, reflowing by width instead of dropping one.
    @ViewBuilder
    private func layoutTriple(width: CGFloat) -> some View {
        if width >= .threeAcrossWidth {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                topModelsCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                byHarnessCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                byProjectCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            // The row takes the tallest card's height, and the cards in it
            // fill that, exactly like the quota panels on Home. Without the
            // fixed size the row would grow to whatever height was going
            // spare and every card with it.
            .fixedSize(horizontal: false, vertical: true)
        } else if width >= .twoColumnWidth {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    topModelsCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    byHarnessCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
                byProjectCard
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                topModelsCard
                byHarnessCard
                byProjectCard
            }
        }
    }

    private var topModelsCard: some View {
        Card(title: "Top models", subtitle: "List-rate value", fillsHeight: true) {
            MiniList(rows: model.byModel, showsValue: true, monospaced: true)
        }
    }

    private var byHarnessCard: some View {
        Card(title: "By harness", subtitle: "Which agent produced the tokens", fillsHeight: true) {
            MiniList(
                rows: model.bySource,
                showsValue: false,
                monospaced: false,
                isHarness: true
            )
        }
    }

    /// The project list, or nothing when the archive has no projects yet.
    @ViewBuilder
    private var byProjectCard: some View {
        if !model.byProject.isEmpty {
            Card(title: "By project", subtitle: "Where the work happened", fillsHeight: true) {
                MiniList(rows: model.byProject, showsValue: false, monospaced: true)
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.focusedDay != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBackToHome?()
                } label: {
                    Label("Home", systemImage: "chevron.left")
                }
                .help("Back to Home")
            }
        }
        ToolbarItem {
            Picker("Period", selection: $model.period) {
                ForEach(InsightsModel.Period.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Button {
                Task { await model.scan() }
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .labelStyle(.iconOnly)
            .disabled(model.isScanning || model.scanCooldownUntil != nil)
            .help("Read new sessions from supported local tools into the archive")
        }
        ToolbarItem {
            Button {
                Task { await model.fetchRemotes() }
            } label: {
                if model.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
            }
            .labelStyle(.iconOnly)
            .disabled(model.isFetching || model.fetchCooldownUntil != nil)
            .help("Fetch usage from remote vendors such as Cursor")
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

    var body: some View {
        if rows.isEmpty {
            EmptyHint(
                symbol: "tray",
                title: "Nothing recorded",
                text: "No usage landed in this period. Scan, or widen the time range."
            )
        } else {
            VStack(spacing: 0) {
                header
                ForEach(rows) { row in
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
                    Divider().opacity(0.3)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("SESSIONS").frame(width: 66, alignment: .trailing)
            Text("TOKENS").frame(width: 66, alignment: .trailing)
            if showsValue {
                Text("VALUE").frame(width: 88, alignment: .trailing)
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
            Text(isHarness ? harnessName(row.key) : (row.key.isEmpty ? "unknown" : row.key))
                .font(monospaced ? Theme.mono(12) : .system(size: 13))
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
                    .help(row.value.caveat ?? "")
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

/// A short list for the overview cards.
private struct MiniList: View {
    var rows: [Bucket]
    var showsValue: Bool
    var monospaced: Bool
    var isHarness: Bool = false
    var limit: Int = 6

    var body: some View {
        if rows.isEmpty {
            EmptyHint(text: "Nothing recorded yet.")
        } else {
            VStack(spacing: Theme.Space.s) {
                ForEach(rows.prefix(limit)) { row in
                    HStack(spacing: Theme.Space.m) {
                        if isHarness {
                            HarnessMark(id: row.key, size: 15)
                        }
                        Text(isHarness ? harnessName(row.key) : (row.key.isEmpty ? "unknown" : row.key))
                            .font(monospaced ? Theme.mono(12) : .system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatTokens(row.counters.total))
                            .font(Theme.numeric(12))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                        if showsValue {
                            Text(row.value.formatted)
                                .font(Theme.numeric(12))
                                .lineLimit(1)
                                .frame(width: 84, alignment: .trailing)
                                .help(row.value.caveat ?? "")
                        }
                    }
                }
                if rows.count > limit {
                    Text("and \(rows.count - limit) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct DailyChart: View {
    var rows: [Bucket]
    @State private var selectedDay: String?

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
                title: "No usage in this period",
                text: "The days you picked have no events. Try a wider range."
            )
        } else {
            Chart(rows) { row in
                BarMark(
                    x: .value("Day", row.key),
                    y: .value("Tokens", Double(row.counters.total)),
                    // Capped, not proportional. A categorical axis gives every
                    // bar an equal share of the plot, so filtering to one day
                    // drew a single bar the width of the card: a block, with no
                    // shape to read and nothing to compare it against.
                    width: rows.count > 12 ? .automatic : .fixed(36)
                )
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(2)
                if selectedDay == row.key {
                    RuleMark(x: .value("Selected day", row.key))
                        .foregroundStyle(Theme.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .chartXAxis {
                // Chart's automatic count still crowds: with 30 categorical
                // bars it wants a label per bar and they overlap into an
                // unreadable smear. Pick the marks explicitly from the data,
                // roughly eight across whatever the period is, and drop the
                // year since every bar shares it.
                AxisMarks(values: labelledDays) { value in
                    AxisValueLabel {
                        if let day = value.as(String.self) {
                            Text(shortDay(day))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) {
                            Text(formatTokens(UInt64(max(0, tokens)))).font(.caption2)
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
            .frame(height: 170)
        }
    }

    /// The data for the day under the pointer, as a floating chip.
    private func hoverSummary(for row: Bucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shortDay(row.key))
                .font(.caption.weight(.semibold))
            Text("\(formatTokens(row.counters.total)) tokens")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(row.value.formatted)
                .font(Theme.numeric(10, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(Theme.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Space.s))
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
    var title: String = "Nothing here yet"
    var text: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 44, height: 44)
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text(title)
                .font(.callout.weight(.medium))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
    }
}
