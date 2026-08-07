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
    /// Dismisses the pane. Owned by the root view, which is the only place the
    /// inspector's presence is decided.
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Spacer()
                    InspectorCloseButton(action: onClose)
                }
                period
                selection
                archive
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.sidebarMaterial)
    }

    /// Panels rather than sections divided by rules.
    ///
    /// This pane used to be flat label/value rows separated by dividers, which
    /// made it the one surface in the app that did not look like the rest of
    /// it. Home is cards, Insights is cards, and the inspector is now the same
    /// object at sidebar width.
    private var period: some View {
        Card(title: "This period", subtitle: nil) {
            if isEmptyArchive {
                nothingScanned
            } else {
                periodFigures
            }
        }
    }

    /// Nothing at all, as opposed to nothing yet or nothing readable.
    ///
    /// An archive that has been read and holds no events is a machine where
    /// nobody has scanned. A load still in flight is not, and neither is one
    /// that failed, so both of those keep the figures and let the screen's own
    /// banner do the talking.
    private var isEmptyArchive: Bool {
        guard let totals = model.totals else { return false }
        return totals.events == 0 && model.errorMessage == nil && !model.isLoading
    }

    /// An archive with nothing in it is not an error and not a zero: it is a
    /// machine where nobody has scanned yet, and every figure on this pane
    /// reading "$0.00" says the opposite of that.
    private var nothingScanned: some View {
        EmptyState(
            symbol: "tray",
            title: "Nothing scanned yet",
            message: """
            tokenstat reads the session logs the tools on this machine already \
            write. Run a scan and this fills in.
            """
        )
    }

    private var periodFigures: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Stat(
                label: "Value at list rates",
                value: model.periodValue.formatted,
                note: "not billed",
                tint: Theme.accent,
                // 26pt reads at full size; below the display fit it stops
                // shrinking the value and drops a step instead, which keeps
                // the headline figure legible in a 960×600 window.
                size: DisplayFit.factor < 1 ? 22 : 26
            )

            if let caveat = model.periodValue.caveat {
                Text(caveat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Side by side where the pane is wide enough, stacked when the
            // inspector is squeezed by a small window. A fixed pair of rows
            // was what ran past the pane's edge at a low effective resolution.
            statPair(
                "Tokens", formatTokens(model.totals?.counters.total ?? 0),
                "Sessions", "\(model.totals?.sessions ?? 0)"
            )
            statPair(
                "Events", formatTokens(model.totals?.events ?? 0),
                "Active days", "\(model.totals?.days ?? 0)"
            )

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

    /// The selected row, or an invitation to select one.
    ///
    /// The panel used to disappear when nothing was selected, so the pane
    /// changed height as you clicked around and the counters that only exist
    /// here were a feature you had to discover by accident.
    @ViewBuilder
    private var selection: some View {
        Card(title: "Selected", subtitle: nil) {
            if let row = model.selected {
                selection(row)
            } else {
                EmptyState(
                    symbol: "hand.tap",
                    title: "Nothing selected",
                    message: """
                    Pick a row on the left to see what it is made of: fresh \
                    input, cache, output, and what the tools did not report.
                    """
                )
            }
        }
    }

    private func selection(_ row: Bucket) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
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

            statPair(
                "Sessions", "\(row.sessions)",
                "Events", formatTokens(row.events)
            )

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

    /// Two headline numbers, side by side when there is room and stacked when
    /// the pane is squeezed.
    ///
    /// The stacked fallback keeps the stats `expands: false` so the label and
    /// value stay together instead of a value ending up a metre from its label
    /// in a full-width row.
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
        Card(title: "Archive", subtitle: nil) {
            archiveRows
        }
    }

    private var archiveRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
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
                    Text("No price book yet, so values are estimated from the model catalog. The app refreshes the price book automatically; the first fetch can take a moment on a fresh install.")
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
            Text(value.map { formatTokens($0) } ?? "n/a")
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
