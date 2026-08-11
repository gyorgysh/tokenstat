// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// How much of each plan is left, on Home rather than in a tab of its own.
///
/// It had a tab, and a tab was too much furniture for it. The phone exists to
/// answer two questions, and both belong on the screen that opens: what did I
/// spend, and what have I got left. A person who wants the second one should
/// not have to know it lives one tap away under a gauge icon.
///
/// **Never a bare percentage.** Every reading carries when it was taken, and a
/// stale one says so. `limits.rs` makes the argument in the core and it holds
/// hardest here: a number with no date, on the screen where somebody decides
/// whether to keep working, is a quiet lie about their quota.
struct ClientLimitsCard: View {
    let providers: [ProviderLimits]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Plan limits")
                .font(ClientType.sectionTitle)

            if isLoading {
                ClientWireframe.Rows(count: 2)
            } else if readable.isEmpty {
                // Not an error. No machine on this account has reported a
                // reading yet, which is the normal state until the limits
                // endpoint ships (P2 in `docs/mobile-app.md`). Saying so beats
                // an empty card, and beats inventing a zero.
                Text("No readings yet. A device on your account reports these "
                    + "while it runs, and they show up here.")
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(sorted) { provider in
                    ProviderRow(provider: provider)
                }
            }
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }

    /// Only providers with an actual reading.
    ///
    /// The host answers `usage.limits` by reading vendor credentials **on the
    /// machine it runs on**, and a phone is not that machine: it has no Claude
    /// Code login, no Cursor session and no API key. So every provider comes
    /// back with a note like "not signed in to Claude Code on this device",
    /// which is true of the phone and completely misleading to read on one.
    ///
    /// Dropping them leaves the honest empty line until the limits endpoint
    /// ships (P2), when readings arrive from the machines that really did take
    /// them. The rows are kept, not deleted: the shape is what P2 fills in, and
    /// a reading that reaches a phone through the account is worth drawing
    /// exactly like this.
    private var readable: [ProviderLimits] {
        providers.filter(\.hasWindows)
    }

    /// Closest to full first. The window about to stop somebody working is the
    /// one worth the top of the card.
    private var sorted: [ProviderLimits] {
        readable.sorted { a, b in
            let peak = { (p: ProviderLimits) in p.windows.map(\.percent).max() ?? -1 }
            return peak(a) > peak(b)
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderLimits

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                HarnessMark(id: provider.source, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(harnessName(provider.source))
                        .font(ClientType.label.weight(.medium))
                    if let plan = provider.plan {
                        Text(plan)
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Text(observed)
                    .font(ClientType.caption)
                    .foregroundStyle(provider.isStale ? Theme.warning : .secondary)
            }

            if provider.hasWindows {
                ForEach(provider.windows) { window in
                    WindowGauge(window: window)
                }
            } else if let note = provider.note {
                // "We could not look" is a different answer from "nothing is
                // used", and the two must not render alike.
                Text(note)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .contain)
    }

    /// When this was read, in words. A reading with no date is not a reading.
    private var observed: String {
        guard let at = provider.observedAt else { return "no date" }
        let ago = at.formatted(.relative(presentation: .numeric))
        return provider.isStale ? "stale, \(ago)" : ago
    }
}

private struct WindowGauge: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(colour)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule()
                        .fill(colour)
                        .frame(width: max(3, geo.size.width * window.fraction))
                }
            }
            .frame(height: 6)
            if let resets = window.resetsAt {
                Text("resets \(resets.formatted(.relative(presentation: .numeric)))")
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label), \(Int(window.percent.rounded())) percent used")
    }

    /// Severity is the renderer's decision, taken from the core's thresholds
    /// rather than reinvented here, and deliberately never stored server side.
    private var colour: Color {
        switch window.severity {
        case .critical: return Theme.danger
        case .warning: return Theme.warning
        case .normal: return Theme.accent
        }
    }
}

#endif
