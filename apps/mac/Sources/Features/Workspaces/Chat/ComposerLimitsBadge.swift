// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// At-a-glance quota for the agent this conversation runs on, in the composer.
///
/// "5h 26% · 7d 87%" on the row's right side, with the full windows one tap
/// away. Vendors that report no quota leave no badge rather than a zero:
/// "we could not look" and "nothing is used" are different answers.
///
/// Shares dated readings with Home and Account, refreshing while visible.
struct ComposerLimitsBadge: View {
    /// Canonical source matching runs against this, so "claude" meets the
    /// "claude_code" readings.
    let backend: String

    @State private var readings = PlanLimitsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDetail = false
    private var shared: [ProviderLimits] {
        readings.visible
    }

    /// The readings for the agent this conversation runs on, and nobody
    /// else's. A chat on an agent that reports no quota gets no badge: it
    /// used to borrow the tightest quota anywhere under its owner's name,
    /// which put a Codex window on a Muse chat. Muse is not Codex, and a
    /// number that belongs to another tool cannot answer "can I keep working
    /// in this chat".
    private var provider: ProviderLimits? {
        ComposerLimits.pick(
            backend: backend,
            canonical: harnessCanonicalID,
            providers: shared,
            source: \.source,
            hasWindows: \.hasWindows
        )
    }

    var body: some View {
        // A zero-size leaf that is always there, so the badge is a real view
        // even with nothing to draw. `.task` does not run on a view that
        // resolves to nothing, and the readings it fetches are exactly what
        // decides whether anything is drawn: an empty badge stayed empty for
        // the life of the composer, never having asked. An empty badge draws
        // nothing and the composer's flexible gap takes up its row spacing,
        // so it costs no visible room either.
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if let provider {
                let rows = ComposerLimits.badgeRows(
                    windows: provider.windows, label: \.label, scope: \.scope)
                // Codex reports the account week beside the model's own, so
                // the headline shows general only and the popover below
                // keeps them all, secondaries included.
                let headline = harnessCanonicalID(provider.source) == "codex"
                    ? ComposerLimits.codexHeadlineRows(
                        windows: provider.windows, label: \.label, scope: \.scope)
                    : rows
                if !headline.isEmpty {
                    Button {
                        showingDetail = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: ActionIcon.benchmarks.symbol)
                                .font(Theme.font(10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            summary(for: headline)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("apple.composerlimitsbadge.how_much_of_the_0_subscription_is_left.9b6329e3", "\(harnessName(provider.source))"))
                    .accessibilityLabel(L10n.text("apple.composerlimitsbadge.0_limits_1.5d5c8479", "\(harnessName(provider.source))", "\(summaryText(for: headline))"))
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        ComposerLimitsDetail(
                            source: provider.source,
                            providers: shared,
                            refreshing: readings.isRefreshing,
                            refresh: { Task { try? await readings.refresh(force: true) } }
                        )
                    }
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await readings.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    /// One seated line: "5h 26% · 7d 87%". Each figure wears its own window's
    /// severity, so the one about to stop the work carries the warning rather
    /// than the whole badge.
    private func summary(
        for rows: [(display: String, window: UsageWindow)]
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Text("·")
                        .font(Theme.font(11))
                        .foregroundStyle(.quaternary)
                }
                Text(row.display)
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
                Text("\(Int(row.window.percent.rounded()))%")
                    .font(Theme.numeric(11, weight: .semibold))
                    .foregroundStyle(row.window.severity.tint)
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func summaryText(for rows: [(display: String, window: UsageWindow)]) -> String {
        rows.map { L10n.text("apple.composerlimitsbadge.0_1_percent.f674c60d", "\($0.display)", "\(Int($0.window.percent.rounded()))") }
            .joined(separator: ", ")
    }


}

/// The full windows behind the badge: bars, reset times, and the reading's
/// age, with a way to ask the vendors again.
private struct ComposerLimitsDetail: View {
    let source: String
    let providers: [ProviderLimits]
    var refreshing: Bool
    var refresh: () -> Void

    private var provider: ProviderLimits? {
        providers.first(where: { $0.source == source })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let provider {
            HStack(spacing: Theme.Space.s) {
                HarnessMark(id: provider.source, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(harnessName(provider.source))
                        .font(Theme.font(13, weight: .semibold))
                    if let plan = provider.plan, !plan.isEmpty {
                        Text(plan)
                            .font(Theme.font(11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("common.refresh"), .refresh, action: refresh)
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .environment(\.compactActions, true)
                    .disabled(refreshing)
            }
            let rows = ComposerLimits.badgeRows(
                windows: provider.windows, label: \.label, scope: \.scope)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                detailRow(tag: row.display, window: row.window)
            }
            footer
            } else {
                Text(L10n.text("apple.composerlimitsbadge.no_readings_for_this_agent_yet.1090da6b"))
                    .font(Theme.font(11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.m)
        .frame(minWidth: 264)
    }

    private func detailRow(tag: String, window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.xs) {
                Text(tag)
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.xs)
                Text("\(Int(window.percent.rounded()))%")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(window.severity.tint)
                    .contentTransition(.numericText())
                if let resets = window.resetsAt {
                    Text(L10n.text("apple.composerlimitsbadge.resets_0.7a4480e9", "\(RelativeClock.phrase(for: resets))"))
                        .font(Theme.font(11))
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rowHighlight)
                    Capsule()
                        .fill(window.severity.tint)
                        .frame(width: max(2, proxy.size.width * window.fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.composerlimitsbadge.0_1_percent_used.bae57146", "\(tag)", "\(Int(window.percent.rounded()))"))
    }

    /// When the numbers were read. A reading with no date is not a reading,
    /// least of all on the screen where somebody decides whether to keep
    /// working.
    private var footer: some View {
        Group {
            if let provider, let observed = provider.observedAt {
                Text(provider.isStale
                    ? L10n.text("apple.composerlimitsbadge.stale_read_0.b645f8bb", "\(RelativeClock.phrase(for: observed, style: .abbreviated))")
                    : L10n.text("apple.composerlimitsbadge.read_0.dd1de208", "\(RelativeClock.phrase(for: observed, style: .abbreviated))"))
                    .font(Theme.font(11))
                    .foregroundStyle(provider.isStale ? Theme.warning : .secondary)
            } else if let note = provider?.note {
                Text(note)
                    .font(Theme.font(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
