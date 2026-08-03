// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

import Charts
import SwiftUI

struct InsightsView: View {
    @Bindable var model: InsightsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }

                headline

                Card(
                    title: "Daily volume",
                    subtitle: "Tokens per day, cache included"
                ) {
                    DailyChart(rows: model.daily)
                }

                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card(title: "By model", subtitle: "List-rate value") {
                        Breakdown(rows: model.byModel, showValue: true)
                    }
                    Card(title: "By tool", subtitle: "Where the tokens came from") {
                        Breakdown(rows: model.bySource, showValue: false)
                    }
                }

                Card(title: "By project", subtitle: "Local paths, never synced") {
                    Breakdown(rows: model.byProject, showValue: false, limit: 8)
                }

                footnote
            }
            .padding(Theme.Space.l)
        }
        .navigationTitle("Insights")
        .toolbar { toolbar }
        .overlay { if model.isLoading && model.totals == nil { ProgressView() } }
    }

    private var headline: some View {
        Card(
            title: "This period",
            subtitle: model.periodValue.caveat
        ) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Stat(
                    label: "Value at list rates",
                    value: model.periodValue.formatted,
                    note: "not billed",
                    tint: Theme.accent
                )
                Stat(
                    label: "Tokens",
                    value: formatTokens(model.totals?.counters.total ?? 0)
                )
                Stat(
                    label: "Sessions",
                    value: "\(model.totals?.sessions ?? 0)"
                )
                Stat(
                    label: "Active days",
                    value: "\(model.totals?.days ?? 0)"
                )
            }
        }
    }

    /// The two facts that decide whether any number above can be trusted.
    @ViewBuilder
    private var footnote: some View {
        if let info = model.info {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if !info.hasPrices {
                    Label(
                        "No price book yet, so every value reads as zero. Run `tokenstat pricing --refresh`.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("Rates effective \(info.priceBookEffectiveFrom).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("Everything here was read from this machine. Nothing left it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, Theme.Space.xs)
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
                    Label("Scan", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isScanning)
            .help("Read new sessions from every supported tool into the archive")
        }
    }
}

private struct ErrorBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

private struct DailyChart: View {
    var rows: [Bucket]

    var body: some View {
        if rows.isEmpty {
            EmptyHint(text: "No usage in this period.")
        } else {
            Chart(rows) { row in
                BarMark(
                    x: .value("Day", row.key),
                    y: .value("Tokens", Double(row.counters.total))
                )
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                // One label per bar is unreadable at 90 days, and the exact
                // date is available on hover anyway.
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let day = value.as(String.self) {
                            Text(day.suffix(5))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Double.self) {
                            Text(formatTokens(UInt64(max(0, tokens))))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 190)
        }
    }
}

private struct Breakdown: View {
    var rows: [Bucket]
    var showValue: Bool
    var limit: Int = 6

    private var shown: ArraySlice<Bucket> { rows.prefix(limit) }
    private var maxTokens: Double {
        Double(rows.first?.counters.total ?? 1)
    }

    var body: some View {
        if rows.isEmpty {
            EmptyHint(text: "Nothing recorded yet.")
        } else {
            VStack(spacing: Theme.Space.s) {
                ForEach(shown) { row in
                    HStack(spacing: Theme.Space.m) {
                        Text(row.key.isEmpty ? "unknown" : row.key)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(formatTokens(row.counters.total))
                            .font(Theme.numeric(12))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)

                        if showValue {
                            Text(row.value.formatted)
                                .font(Theme.numeric(12))
                                .lineLimit(1)
                                .frame(width: 96, alignment: .trailing)
                                .help(row.value.caveat ?? "")
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        // A share bar behind the row rather than a separate
                        // column: the comparison is the point, the exact
                        // percentage is not.
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.secondary.opacity(0.22))
                                .frame(
                                    width: geo.size.width
                                        * min(1, Double(row.counters.total) / max(1, maxTokens)),
                                    height: 2
                                )
                        }
                        .frame(height: 2)
                        .offset(y: 3)
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

private struct EmptyHint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Space.s)
    }
}
