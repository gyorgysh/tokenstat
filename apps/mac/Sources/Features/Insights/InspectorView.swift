// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The right pane: what the period adds up to, and what the selected row is.
///
/// Deliberately the only place that shows the caveats in full. A table cell has
/// room for a `+` and nothing else, so the reason behind it lives here rather
/// than in a tooltip nobody hovers.
struct InspectorView: View {
    var model: InsightsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                period
                if let row = model.selected {
                    Divider()
                    selection(row)
                }
                Divider()
                archive
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.sidebarMaterial)
    }

    private var period: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "This period")

            Stat(
                label: "Value at list rates",
                value: model.periodValue.formatted,
                note: "not billed",
                tint: Theme.accent,
                size: 26
            )

            if let caveat = model.periodValue.caveat {
                Text(caveat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Space.m) {
                Stat(label: "Tokens", value: formatTokens(model.totals?.counters.total ?? 0), size: 15)
                Stat(label: "Sessions", value: "\(model.totals?.sessions ?? 0)", size: 15)
            }
            HStack(spacing: Theme.Space.m) {
                Stat(label: "Events", value: formatTokens(model.totals?.events ?? 0), size: 15)
                Stat(label: "Active days", value: "\(model.totals?.days ?? 0)", size: 15)
            }

            if let block = model.activeBlock {
                Divider()
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Circle().fill(Theme.secondary).frame(width: 6, height: 6)
                        Text("Block open")
                            .font(.caption.weight(.medium))
                    }
                    Text("\(formatTokens(block.counters.total)) since \(block.start.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selection(_ row: Bucket) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel(text: "Selected")

            Text(row.key.isEmpty ? "unknown" : row.key)
                .font(Theme.mono(12))
                .textSelection(.enabled)
                .lineLimit(3)

            Stat(label: "Value", value: row.value.formatted, size: 18)
            if let caveat = row.value.caveat {
                Text(caveat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Counters split out one by one. This is the view where the
            // difference between "not reported" and "zero" is visible, and a
            // dash is the whole point: it means the tool never said.
            VStack(spacing: Theme.Space.xs) {
                CounterRow(label: "Fresh input", value: row.counters.inputFresh)
                CounterRow(label: "Cache read", value: row.counters.cacheRead)
                CounterRow(label: "Cache write 5m", value: row.counters.cacheWrite5m)
                CounterRow(label: "Cache write 1h", value: row.counters.cacheWrite1h)
                CounterRow(label: "Output", value: row.counters.output)
            }

            if row.counters.hasUnknown {
                Text("A dash means the tool does not report that counter, which is not the same as zero.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: Theme.Space.m) {
                Stat(label: "Sessions", value: "\(row.sessions)", size: 15)
                Stat(label: "Events", value: formatTokens(row.events), size: 15)
            }

            // Which agents produced this project's usage. Only meaningful on
            // the Projects tab: on any other tab the key is not a project.
            if model.tab == .projects {
                let harnesses = model.harnesses(inProject: row.key)
                if !harnesses.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Harnesses here")
                            .font(.caption.weight(.medium))
                        ForEach(harnesses) { h in
                            HStack(spacing: Theme.Space.s) {
                                HarnessMark(id: h.split, size: 14)
                                Text(harnessName(h.split))
                                    .font(.caption)
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
                    Text("Unpriced models")
                        .font(.caption.weight(.medium))
                    ForEach(row.unpricedModels, id: \.self) { model in
                        Text(model)
                            .font(Theme.mono(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Archive")
            if let info = model.info {
                KeyValue(key: "Timezone", value: info.timezone)
                KeyValue(key: "Core", value: info.coreVersion)
                // Worth stating, because it decides whether a terminal survives
                // quitting the app. In-process means this window owns every
                // process it starts, and they go when it does.
                KeyValue(key: "Host", value: Bridge.isHosted ? "daemon" : "in-process")
                if info.hasPrices {
                    KeyValue(key: "Rates from", value: info.priceBookEffectiveFrom)
                } else {
                    Text("No price book yet, so every value reads as zero. Run `tokenstat pricing --refresh`.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            Text("Read from this machine. Nothing left it.")
                .font(.caption)
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.map { formatTokens($0) } ?? "—")
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(Theme.mono(10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
