// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

struct ClientInsightFacts {
    static func panels(
        tokens: UInt64,
        events: UInt64,
        count: Int,
        countLabel: String,
        formatCompact: (UInt64) -> String
    ) -> [(label: String, value: String, mark: String)] {
        [
            (label: L10n.text("apple.clientinsightfacts.tokens.a039dfb9"), value: formatCompact(tokens), mark: "mark_insights"),
            (label: L10n.text("apple.clientinsightfacts.events.8d14f6e7"), value: formatCompact(events), mark: "mark_activity"),
            (label: countLabel, value: "\(count)", mark: "mark_examples"),
        ]
    }
}
