// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// What is left of each plan, as the vendor reports it, one panel per vendor.
///
/// A different question from the rest of Insights, which prices what was spent.
/// These are quota windows, and the numbers are the vendor's own. Nothing here
/// is derived from the archive: a percentage we worked out would be a guess
/// wearing a number's clothes, and someone deciding whether to start another
/// session needs the real one.
///
/// One card per vendor rather than one card listing all of them. The old single
/// card put five unrelated tools in one column, so a machine with everything
/// installed had a card taller than the window while a machine with one tool had
/// a card with a single row rattling around in it. A vendor with nothing to say
/// is left out entirely: the panels a person sees are the tools they actually
/// have.
enum PlanLimits {
    /// Vendors worth a panel: anything that reported numbers, plus anything
    /// whose failure is worth reading. A tool that is simply not installed is
    /// not a failure and does not get one.
    static func visible(_ providers: [ProviderLimits]) -> [ProviderLimits] {
        providers.filter { provider in
            if provider.hasWindows { return true }
            guard let note = provider.note?.lowercased() else { return false }
            return !isAbsent(note)
        }
    }

    /// Do not turn an absent tool into an error card. Once a tool is present,
    /// authentication, network, and rate-limit failures remain visible.
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

/// One vendor's quota, in its own panel.
struct PlanLimitPanel: View {
    let provider: ProviderLimits
    let isLoading: Bool
    /// True when this panel shares a row with others and has to match them.
    var fillsHeight = false
    let refresh: () -> Void

    var body: some View {
        Card(
            title: harnessName(provider.source),
            subtitle: subtitle,
            accessory: AnyView(header),
            fillsHeight: fillsHeight
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if provider.hasWindows {
                    ForEach(provider.windows) { window in
                        WindowBar(window: window)
                    }
                    if provider.isStale, let note = provider.note {
                        // Why the numbers stopped moving, under the numbers
                        // themselves. A refresh that fails is not a reason to
                        // hide what was true an hour ago, and it is not a reason
                        // to pass that off as current either.
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let note = provider.note {
                    // Words, not a zero bar. "We could not look" and "nothing
                    // used" are different answers and must not look the same.
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The plan name when the vendor gave one, and always how old the reading
    /// is. "As of" rather than a bare timestamp, because with a stale panel the
    /// age is the point.
    private var subtitle: String? {
        var parts: [String] = []
        if let plan = provider.plan, !plan.isEmpty {
            parts.append(plan.capitalized)
        }
        if let observed = provider.observedAt {
            let age = observed.formatted(.relative(presentation: .named))
            parts.append(provider.isStale ? "last read \(age)" : "read \(age)")
        }
        if provider.hasWindows, let next = provider.nextReset, next > .now {
            parts.append("next window \(next.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            if provider.isStale {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .help("Cached. The vendor could not be reached on the last refresh.")
            }
            HarnessMark(id: provider.source, size: 18)
            Button(action: refresh) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Ask each vendor again")
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
                    // The shared tick, not `format: .relative`. One live time
                    // source per quota window kept the whole window in a
                    // layout pass every frame. See `RelativeClock`.
                    Text("· resets \(RelativeClock.phrase(for: resets))")
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
