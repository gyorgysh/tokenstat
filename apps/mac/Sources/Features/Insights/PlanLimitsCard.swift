// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// What is left of each plan, as the vendor reports it.
///
/// A different question from the rest of Insights, which prices what was spent.
/// These are quota windows, and the numbers are the vendor's own. Nothing here
/// is derived from the archive: a percentage we worked out would be a guess
/// wearing a number's clothes, and someone deciding whether to start another
/// session needs the real one.
struct PlanLimitsCard: View {
    let providers: [ProviderLimits]
    let isLoading: Bool
    let refresh: () -> Void

    private var visibleProviders: [ProviderLimits] {
        providers.filter { provider in
            guard let note = provider.note?.lowercased() else { return true }
            return !Self.isUnavailable(note)
        }
    }

    var body: some View {
        Card(
            title: "Plan limits",
            subtitle: "What each vendor says is left, not what we counted.",
            accessory: AnyView(refreshButton)
        ) {
            if visibleProviders.isEmpty {
                Text(isLoading ? "Reading…" : "No providers reported a limit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ForEach(visibleProviders) { provider in
                        ProviderRow(provider: provider)
                    }
                }
            }
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help("Ask each vendor again")
    }

    /// Do not turn an absent tool into an error card. Once a tool is present,
    /// authentication, network, and rate-limit failures remain visible.
    private static func isUnavailable(_ note: String) -> Bool {
        [
            "not found",
            "not running",
            "no sessions",
            "no cursor session",
            "no opencode",
            "no antigravity",
            "no codex",
            "not signed in",
            "no claude code",
            "no home directory",
        ].contains { note.contains($0) }
    }
}

private struct ProviderRow: View {
    let provider: ProviderLimits

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                HarnessMark(id: provider.source, size: 20)
                Text(harnessName(provider.source))
                    .font(.system(size: 13, weight: .medium))
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan.capitalized)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: Theme.Space.xs)
                if let observed = provider.observedAt {
                    Text(observed, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("When these numbers were true")
                }
            }

            if let note = provider.note {
                // Words, not a zero bar. "We could not look" and "nothing used"
                // are different answers and must not look the same.
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(provider.windows) { window in
                    WindowBar(window: window)
                }
            }
        }
    }
}

private struct WindowBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.xs) {
                Text(window.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.xs)
                Text("\(Int(window.percent.rounded()))%")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(window.severity.tint)
                if let resets = window.resetsAt {
                    Text("· resets \(resets, format: .relative(presentation: .named))")
                        .font(.system(size: 11))
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
    }
}
