// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import OSLog
import SwiftUI

/// At-a-glance quota for the agent this conversation runs on, in the composer.
///
/// "5h 26% · 7d 87%" on the row's right side, with the full windows one tap
/// away. Vendors that report no quota leave no badge rather than a zero:
/// "we could not look" and "nothing is used" are different answers.
///
/// Reads the cached readings on appear and asks the vendors live only when
/// the cache holds nothing for this agent, the same rule the Account screen
/// uses. A manual refresh lives in the popover for the moment somebody is
/// deciding whether to start another session.
struct ComposerLimitsBadge: View {
    private static let log = Logger(
        subsystem: "ai.tokenstat.tokenstat", category: "limits")

    /// Canonical source matching runs against this, so "claude" meets the
    /// "claude_code" readings.
    let backend: String

    @State private var providers: [ProviderLimits] = []
    @State private var skip: Set<String> = []
    @State private var refreshing = false
    @State private var showingDetail = false
    /// When vendors were last asked live, per backend across composer mounts.
    /// Per-view state resets on every conversation switch and re-fires the
    /// live probe; the throttle belongs to the backend, not the view.
    /// Bounded: backends are a small fixed set, but a static dict must not
    /// grow without limit if new ids ever appear.
    private static var lastLiveAttemptByBackend: [String: Date] = [:]
    private static let liveAttemptCap = 64

    private var shared: [ProviderLimits] {
        providers.filter { !skip.contains($0.source) }
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
                    .help("\(harnessName(provider.source)) plan limits. Shows the full windows.")
                    .accessibilityLabel("\(harnessName(provider.source)) limits: \(summaryText(for: headline))")
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        ComposerLimitsDetail(
                            source: provider.source,
                            providers: shared,
                            refreshing: refreshing,
                            refresh: { Task { await refresh() } }
                        )
                    }
                }
            }
        }
        .task(id: backend) {
            await load()
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
        rows.map { "\($0.display) \(Int($0.window.percent.rounded())) percent" }
            .joined(separator: ", ")
    }

    private func apply(_ state: LimitsSyncState) {
        skip = Set(state.skip)
        let visible = PlanLimits.visible(state.providers).filter { !skip.contains($0.source) }
        // Always assign so a revoked/empty reading clears a stale badge.
        providers = visible
    }

    private func load() async {
        let cached: LimitsSyncState
        do {
            cached = try await Bridge.limitsSync()
        } catch {
            Self.log.error("composer badge cache read failed: \(error.localizedDescription, privacy: .public)")
            cached = LimitsSyncState()
        }
        apply(cached)
        Self.log.debug("composer badge backend=\(self.backend, privacy: .public) cached=\(cached.providers.count, privacy: .public) shown=\(self.provider?.source ?? "none", privacy: .public)")
        guard provider == nil else { return }
        // Live only when the cache has nothing for this agent, and at most
        // every five minutes: backends without vendor readings must not ask
        // on every composer mount. The popover's Refresh always asks.
        let last = Self.lastLiveAttemptByBackend[backend]
        guard last.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        Self.noteLiveAttempt(backend: backend)
        await refresh()
        Self.log.debug("composer badge live backend=\(self.backend, privacy: .public) shown=\(self.provider?.source ?? "none", privacy: .public)")
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard let fresh = try? await Bridge.usageLimits() else { return }
        let visible = PlanLimits.visible(fresh).filter { !skip.contains($0.source) }
        providers = visible
    }

    private static func noteLiveAttempt(backend: String) {
        if lastLiveAttemptByBackend[backend] == nil, lastLiveAttemptByBackend.count >= liveAttemptCap,
           let drop = lastLiveAttemptByBackend.keys.sorted().first {
            lastLiveAttemptByBackend.removeValue(forKey: drop)
        }
        lastLiveAttemptByBackend[backend] = Date()
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
                Button("Refresh", .refresh, action: refresh)
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
                Text("No readings for this agent yet.")
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
                    Text("· resets \(RelativeClock.phrase(for: resets))")
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
        .accessibilityLabel("\(tag), \(Int(window.percent.rounded())) percent used")
    }

    /// When the numbers were read. A reading with no date is not a reading,
    /// least of all on the screen where somebody decides whether to keep
    /// working.
    private var footer: some View {
        Group {
            if let provider, let observed = provider.observedAt {
                Text(provider.isStale
                    ? "Stale, read \(RelativeClock.phrase(for: observed, style: .abbreviated))"
                    : "Read \(RelativeClock.phrase(for: observed, style: .abbreviated))")
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
