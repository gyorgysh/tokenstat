// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// The three figures under Insights' "This period" total, in display order.
///
/// Tokens, events, then the current cut's own count (models, harnesses or
/// days). The view draws one panel per pair, so each keeps its own card on
/// every width, the way the Mac's overview draws one metric card per figure.
///
/// Deliberately free of the model layer: the compact token formatter is
/// injected, so this compiles anywhere Foundation does, including the
/// standalone test runner.
struct ClientInsightFacts {
    static func panels(
        tokens: UInt64,
        events: UInt64,
        count: Int,
        countLabel: String,
        formatCompact: (UInt64) -> String
    ) -> [(label: String, value: String)] {
        [
            (label: "Tokens", value: formatCompact(tokens)),
            (label: "Events", value: events.formatted()),
            (label: countLabel, value: "\(count)"),
        ]
    }
}
