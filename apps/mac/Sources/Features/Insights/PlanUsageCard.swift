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
            title: "Plan usage",
            subtitle: "Subscription-covered usage recorded in the archive",
            fillsHeight: fillsHeight
        ) {
            if rows.isEmpty {
                Text("No plan-covered usage recorded in this period.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: Theme.Space.s) {
                            HarnessMark(id: row.key, size: 20)
                            Text(harnessName(row.key))
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: Theme.Space.s)
                            Text(formatTokens(row.counters.total))
                                .font(Theme.numeric(13, weight: .medium))
                            Text("tokens")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
            }
        }
    }
}
