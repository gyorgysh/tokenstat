// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Archive usage that the source marked as covered by a subscription.
///
/// This is deliberately separate from `PlanLimitsCard`: vendor quota windows
/// answer what is left, while this answers what the archive has already seen.
/// A source can have plan usage without publishing a remaining-limit endpoint.
struct PlanUsageCard: View {
    let rows: [Bucket]
    /// True when this card shares a row with others and has to match them.
    var fillsHeight = false

    var body: some View {
        Card(
            title: L10n.text("apple.planusagecard.plan_usage.eb55e923"),
            subtitle: L10n.text("apple.planusagecard.subscription_covered_usage_recorded_in_the.e96aa3c3"),
            mark: "mark_plan",
            fillsHeight: fillsHeight
        ) {
            if rows.isEmpty {
                Text(L10n.text("apple.planusagecard.no_plan_covered_usage_recorded_in_this_per.020d7a22"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: Theme.Space.s) {
                            HarnessMark(id: row.key, size: 20)
                            Text(harnessName(row.key))
                                .font(Theme.font(13, weight: .medium))
                            Spacer(minLength: Theme.Space.s)
                            Text(formatTokens(row.counters.total))
                                .font(Theme.numeric(13, weight: .medium))
                            Text(L10n.text("apple.planusagecard.tokens.c51e455b"))
                                .font(Theme.font(11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
            }
        }
    }
}
