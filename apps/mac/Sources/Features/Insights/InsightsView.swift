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

                switch model.tab {
                case .overview:
                    overview
                case .models, .projects, .harnesses, .sessions:
                    BreakdownTable(
                        rows: model.rows,
                        selected: $model.selected,
                        showsValue: model.tab == .models,
                        // A session id or a project path is read character by
                        // character. A harness has a name, not an id.
                        monospaced: model.tab != .harnesses,
                        isHarness: model.tab == .harnesses
                    )
                }
            }
            .padding(Theme.Space.m)
        }
        .overlay {
            if model.isLoading && model.totals == nil {
                ProgressView()
            }
        }
    }

    private var overview: some View {
        // The plan limit and plan usage cards used to open this screen. They
        // moved to Home: "what is left of the allowance" is asked before the
        // work, not while reading a report about it.
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Card(title: "Daily volume", subtitle: "Tokens per day, cache included") {
                DailyChart(rows: model.daily)
            }

            // Three across once there is room for it. Two cards on a
            // full-screen window are two wide boxes of short rows with a page
            // of nothing under them, and the projects breakdown was already
            // loaded and only reachable through a tab.
            WidthReader { width in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Card(title: "Top models", subtitle: "List-rate value") {
                        MiniList(rows: model.byModel, showsValue: true, monospaced: true)
                    }
                    Card(title: "By harness", subtitle: "Which agent produced the tokens") {
                        MiniList(
                            rows: model.bySource,
                            showsValue: false,
                            monospaced: false,
                            isHarness: true
                        )
                    }
                    if width >= .twoColumnWidth, !model.byProject.isEmpty {
                        Card(title: "By project", subtitle: "Where the work happened") {
                            MiniList(rows: model.byProject, showsValue: false, monospaced: true)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
            EmptyHint(text: "Nothing recorded in this period.")
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

    var body: some View {
        if rows.isEmpty {
            EmptyHint(text: "No usage in this period.")
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
                        // Resolved against the chart's own bounds, never by
                        // padding the scale. The default makes room for an
                        // annotation by growing the y domain, so hovering a bar
                        // rescaled the axis and squashed every bar on the
                        // screen: the chart moved under the pointer that was
                        // only asking what one day was worth.
                        .annotation(
                            position: .top,
                            alignment: .leading,
                            overflowResolution: AnnotationOverflowResolution(
                                x: .fit(to: .chart),
                                y: .fit(to: .chart)
                            )
                        ) {
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
                        }
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
            .frame(height: 170)
        }
    }
}

struct EmptyHint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Space.s)
    }
}
