// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum PlanLimits {
    static func visible(_ providers: [ProviderLimits]) -> [ProviderLimits] {
        providers.filter { provider in
            if provider.hasWindows { return true }
            guard let note = provider.note?.lowercased() else { return false }
            return !isAbsent(note)
        }
    }

    static func isAbsent(_ note: String) -> Bool {
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

struct PlanLimitPanel: View {
    let provider: ProviderLimits
    let isLoading: Bool
    var fillsHeight = false
    var profileTitle: String? = nil
    let refresh: () -> Void

    var body: some View {
        Card(
            title: profileTitle.map { "\(harnessName(provider.source)) · \($0)" } ?? harnessName(provider.source),
            subtitle: subtitle,
            leading: AnyView(HarnessMark(id: provider.source, size: 22)),
            accessory: AnyView(header),
            fillsHeight: fillsHeight
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if provider.hasWindows {
                    ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                        WindowBar(window: window)
                    }
                    if provider.isStale, let note = provider.note {
                        Text(note)
                            .font(Theme.font(11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let note = provider.note {
                    Text(note)
                        .font(Theme.font(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let plan = provider.plan, !plan.isEmpty {
            parts.append(plan.capitalized)
        }
        if let observed = provider.observedAt {
            let age = observed.formatted(.relative(presentation: .named))
            parts.append(provider.isStale ? L10n.text("apple.planlimitscard.last_read_0.ee7c4998", "\(age)") : L10n.text("apple.planlimitscard.read_0.5e63e83a", "\(age)"))
        }
        if provider.hasWindows, let next = provider.nextReset, next > .now {
            parts.append(L10n.text("apple.planlimitscard.next_window_0.fcd7ac2d", "\(next.formatted(.relative(presentation: .named)))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            if provider.isStale {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.warning)
                    .help(L10n.text("apple.planlimitscard.cached_the_vendor_could_not_be_reached_on.8dfff133"))
            }
            Button(action: refresh) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
            .disabled(isLoading)
            .help(L10n.text("apple.planlimitscard.ask_each_vendor_again.0c1778b3"))
        }
    }
}

private struct WindowBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.xs) {
                Text(window.displayLabel)
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.xs)
                Text("\(Int(window.percent.rounded()))%")
                    .font(Theme.numeric(12, weight: .medium))
                    .foregroundStyle(window.severity.tint)
                if let resets = window.resetsAt {
                    Text(L10n.text("apple.planlimitscard.resets_0.7a4480e9", "\(RelativeClock.phrase(for: resets))"))
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
    }
}
