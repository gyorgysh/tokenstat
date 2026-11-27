// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct InspectorView: View {
    var model: InsightsModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: L10n.text("common.insights"), symbol: "chart.bar.xaxis")
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    period
                    selection
                    archive
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .desktopPaneBackground()
    }

    private var period: some View {
        Card(title: L10n.text("apple.inspectorview.this_period.8ed3e11f"), subtitle: nil, mark: "mark_insights") {
            if isEmptyArchive {
                nothingScanned
            } else {
                periodFigures
            }
        }
    }

    private var isEmptyArchive: Bool {
        guard let totals = model.totals else { return false }
        return totals.events == 0 && model.errorMessage == nil && !model.isLoading
    }

    private var nothingScanned: some View {
        EmptyState(
            symbol: "tray",
            title: L10n.text("apple.inspectorview.nothing_scanned_yet.b0a2718e"),
            message: L10n.text("apple.inspectorview.tokenstat_reads_the_session_logs_the_tools.bdd2445b")
        )
    }

    private var periodFigures: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Stat(
                label: L10n.text("apple.inspectorview.api_list_price.060458ef"),
                value: model.periodValue.formatted,
                tint: Theme.accent,
                size: DisplayFit.factor < 1 ? 22 : 26
            )

            statPair(
                L10n.text("apple.inspectorview.tokens.a039dfb9"), formatTokens(model.totals?.counters.total ?? 0),
                L10n.text("apple.inspectorview.sessions.6fa3cbf4"), "\(model.totals?.sessions ?? 0)"
            )
            statPair(
                L10n.text("apple.inspectorview.events.8d14f6e7"), formatTokens(model.totals?.events ?? 0),
                L10n.text("apple.inspectorview.active_days.6cbebfa2"), "\(model.totals?.days ?? 0)"
            )

            if let block = model.activeBlock {
                ThemeRule()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Circle().fill(Theme.secondary).frame(width: 6, height: 6)
                        Text(L10n.text("apple.inspectorview.block_open.1bc5df29"))
                            .font(Theme.caption.weight(.medium))
                    }
                    Text(L10n.text("apple.inspectorview.0_since_1.8570f4f3", "\(formatTokens(block.counters.total))", "\(block.start.formatted(date: .omitted, time: .shortened))"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var selection: some View {
        Card(title: L10n.text("apple.inspectorview.selected.57fd7a0c"), subtitle: nil, mark: "mark_activity") {
            if let row = model.selected {
                selection(row)
            } else {
                EmptyState(
                    symbol: "hand.tap",
                    title: L10n.text("apple.inspectorview.nothing_selected.f8c10424"),
                    message: L10n.text("apple.inspectorview.pick_a_row_on_the_left_to_see_what_it_is_m.4837e049")
                )
            }
        }
    }

    private func selection(_ row: Bucket) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(row.key.isEmpty ? L10n.text("apple.inspectorview.unknown.b23a6a84") : row.key)
                .font(Theme.mono(12))
                .textSelection(.enabled)
                .lineLimit(3)

            Stat(label: L10n.text("apple.inspectorview.value.8e37953d"), value: row.value.formatted, size: 18)

            VStack(spacing: Theme.Space.xs) {
                CounterRow(label: L10n.text("apple.inspectorview.fresh_input.a5156480"), value: row.counters.inputFresh)
                CounterRow(label: L10n.text("apple.inspectorview.cache_read.0008ce30"), value: row.counters.cacheRead)
                CounterRow(label: L10n.text("apple.inspectorview.cache_write_5m.bf7e82f8"), value: row.counters.cacheWrite5m)
                CounterRow(label: L10n.text("apple.inspectorview.cache_write_1h.80055f01"), value: row.counters.cacheWrite1h)
                CounterRow(label: L10n.text("apple.inspectorview.output.b2439bcb"), value: row.counters.output)
            }

            if row.counters.hasUnknown {
                Text(L10n.text("apple.inspectorview.a_dash_means_the_tool_does_not_report_that.ebcc68a5"))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }

            statPair(
                L10n.text("apple.inspectorview.sessions.6fa3cbf4"), "\(row.sessions)",
                L10n.text("apple.inspectorview.events.8d14f6e7"), formatTokens(row.events)
            )

            if model.tab == .projects {
                let harnesses = model.harnesses(inProject: row.key)
                if !harnesses.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.inspectorview.coding_tools_here.599781a1"))
                            .font(Theme.caption.weight(.medium))
                        ForEach(harnesses) { h in
                            HStack(spacing: Theme.Space.s) {
                                HarnessMark(id: h.split, size: 14)
                                Text(harnessName(h.split))
                                    .font(Theme.caption)
                                Spacer()
                                Text(formatTokens(h.counters.total))
                                    .font(Theme.numeric(10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !row.unpricedModels.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(L10n.text("apple.inspectorview.unpriced_models.09fe601e"))
                        .font(Theme.caption.weight(.medium))
                    ForEach(row.unpricedModels, id: \.self) { model in
                        Text(model)
                            .font(Theme.mono(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statPair(
        _ label1: String, _ value1: String,
        _ label2: String, _ value2: String
    ) -> some View {
        // A measured threshold rather than `ViewThatFits`: inside a ScrollView
        // a ViewThatFits can be offered the scroll view's full width and always
        // take the side-by-side branch, which is the overflow it exists to
        // prevent. `WidthReader` hands the pair its actual width.
        WidthReader { width in
            if width >= 260 {
                HStack(spacing: Theme.Space.m) {
                    Stat(label: label1, value: value1, size: 15)
                    Stat(label: label2, value: value2, size: 15)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Stat(label: label1, value: value1, size: 15, expands: false)
                    Stat(label: label2, value: value2, size: 15, expands: false)
                }
            }
        }
    }

    private var archive: some View {
        Card(title: L10n.text("common.archive"), subtitle: nil, mark: "mark_archive") {
            archiveRows
        }
    }

    private var archiveRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let info = model.info {
                KeyValue(key: "Timezone", value: info.timezone)
                KeyValue(key: "Core", value: info.coreVersion)
                KeyValue(key: "Host", value: Bridge.isHosted ? "daemon" : "in-process")
                if info.hasPrices {
                    KeyValue(key: "Rates from", value: info.priceBookEffectiveFrom)
                } else {
                    Text(L10n.text("apple.inspectorview.no_price_book_yet_so_values_are_estimated.3e76ee99"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            Text(L10n.text("apple.inspectorview.read_from_this_device_nothing_left_it.0c693058"))
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
        }
    }
}

private struct CounterRow: View {
    var label: String
    var value: UInt64?

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.map { formatTokens($0) } ?? L10n.text("apple.inspectorview.n_a.a683c5c5"))
                .font(Theme.numeric(11))
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
    }
}

private struct KeyValue: View {
    var key: String
    var value: String

    var body: some View {
        HStack {
            Text(key)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(Theme.mono(10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
