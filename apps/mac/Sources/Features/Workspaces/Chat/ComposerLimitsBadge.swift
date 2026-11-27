// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ComposerLimitsBadge: View {
    let backend: String
    var peer: String?
    var profileID: String? = nil
    var compact = false
    var showUsage: (() -> Void)?

    private var readings: PlanLimitsStore { ChatPlanLimits.store(peer: peer) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDetail = false
    private var shared: [ProviderLimits] {
        readings.visible.filter { $0.profileId == profileID }
    }

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
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if let provider {
                let rows = ComposerLimits.badgeRows(
                    windows: provider.windows, label: \.label, scope: \.scope)
                let headline = harnessCanonicalID(provider.source) == "codex"
                    ? ComposerLimits.codexHeadlineRows(
                        windows: provider.windows, label: \.label, scope: \.scope)
                    : rows
                let compactRow = ComposerLimits.compactRow(rows: headline, label: \.label, percent: \.percent)
                if !headline.isEmpty, !compact || compactRow != nil {
                    Button {
                        showingDetail = true
                    } label: {
                        if compact, let row = compactRow {
                            ZStack {
                                Circle().stroke(Theme.rowHighlight, lineWidth: 3)
                                Circle().trim(from: 0, to: row.window.fraction)
                                    .stroke(provider.isStale ? Color.secondary : row.window.severity == .warning ? Theme.warning : row.window.severity.tint,
                                            style: StrokeStyle(lineWidth: 3, lineCap: .round,
                                                               dash: provider.isStale ? [2, 2] : []))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 20, height: 20)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                        } else {
                            HStack(spacing: 5) {
                                Image(systemName: ActionIcon.benchmarks.symbol)
                                    .font(Theme.font(10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                summary(for: headline)
                            }
                            .contentShape(.rect)
                        }
                    }
                    .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
                    .help(L10n.text("apple.composerlimitsbadge.how_much_of_the_0_subscription_is_left.9b6329e3", "\(harnessName(provider.source))"))
                    .accessibilityLabel(L10n.text("apple.composerlimitsbadge.0_limits_1.5d5c8479", "\(harnessName(provider.source))", "\(summaryText(for: compact ? compactRow.map { [$0] } ?? [] : headline))"))
                    .accessibilityValue(provider.isStale ? L10n.text("common.chat.usage.stale") : "")
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            ComposerLimitsDetail(
                                source: provider.source,
                                providers: shared,
                                refreshing: readings.isRefreshing,
                                refresh: { Task { try? await readings.refresh(force: true) } }
                            )
                            if let showUsage {
                                Button(L10n.text("common.chat.usage.details"), .benchmarks) {
                                    showingDetail = false
                                    showUsage()
                                }
                                .buttonStyle(SecondaryButtonStyle(small: true))
                                .padding([.horizontal, .bottom], Theme.Space.m)
                            }
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
        }
        .task(id: "\(scenePhase):\(peer ?? "local")") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await readings.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func summary(
        for rows: [(display: String, window: UsageWindow)]
    ) -> some View {
        ComposerLimitsLine(rows: rows)
    }

    private func summaryText(for rows: [(display: String, window: UsageWindow)]) -> String {
        rows.map { L10n.text("apple.composerlimitsbadge.0_1_percent.f674c60d", "\($0.display)", "\($0.window.percent.formatted(.number.precision(.fractionLength(0))))") }
            .joined(separator: ", ")
    }


}

struct ComposerLimitsLine: View {
    let rows: [(display: String, window: UsageWindow)]

    var body: some View {
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
                Text("\(row.window.percent.formatted(.number.precision(.fractionLength(0))))%")
                    .font(Theme.numeric(11, weight: .semibold))
                    .foregroundStyle(row.window.severity.tint)
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

struct AgentLimitsSummary: View {
    let backend: String
    var peer: String?
    var profileID: String? = nil

    var body: some View {
        let readings = ChatPlanLimits.store(peer: peer)
        if let provider = ComposerLimits.pick(
            backend: backend, canonical: harnessCanonicalID, providers: readings.visible.filter { $0.profileId == profileID },
            source: \.source, hasWindows: \.hasWindows
        ) {
            let rows = harnessCanonicalID(provider.source) == "codex"
                ? ComposerLimits.codexHeadlineRows(windows: provider.windows, label: \.label, scope: \.scope)
                : ComposerLimits.badgeRows(windows: provider.windows, label: \.label, scope: \.scope)
            if !rows.isEmpty {
                ComposerLimitsLine(rows: rows)
                    .opacity(provider.isStale ? 0.6 : 1)
                    .fixedSize()
                    .accessibilityLabel(rows.map {
                        L10n.text("apple.composerlimitsbadge.0_1_percent.f674c60d", "\($0.display)",
                                  "\($0.window.percent.formatted(.number.precision(.fractionLength(0))))")
                    }.joined(separator: ", "))
            }
        }
    }
}

struct ComposerLimitsDetail: View {
    let source: String
    let providers: [ProviderLimits]
    var refreshing: Bool
    var refresh: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                Text("\(window.percent.formatted(.number.precision(.fractionLength(0))))%")
                    .font(Theme.font(12, weight: .medium).monospacedDigit())
                    .foregroundStyle(window.severity.tint)
                    .contentTransition(.numericText())
                    .fixedSize()
                if !dynamicTypeSize.isAccessibilitySize, let resets = window.resetsAt {
                    resetTime(resets)
                }
            }
            if dynamicTypeSize.isAccessibilitySize, let resets = window.resetsAt {
                resetTime(resets)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rowHighlight)
                    Capsule()
                        .fill(window.severity.tint)
                        .frame(width: proxy.size.width * window.fraction)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.composerlimitsbadge.0_1_percent_used.bae57146", "\(tag)", "\(window.percent.formatted(.number.precision(.fractionLength(0))))"))
        .accessibilityValue(window.resetsAt.map {
            L10n.text("common.chat_resets_at", "\(RelativeClock.phrase(for: $0))")
        } ?? "")
    }

    private func resetTime(_ date: Date) -> some View {
        Text(dynamicTypeSize.isAccessibilitySize
             ? L10n.text("common.chat_resets_at", "\(RelativeClock.phrase(for: date))")
             : L10n.text("apple.composerlimitsbadge.resets_0.7a4480e9", "\(RelativeClock.phrase(for: date))"))
            .font(Theme.font(11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

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
