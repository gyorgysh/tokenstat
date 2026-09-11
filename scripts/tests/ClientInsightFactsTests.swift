// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientInsightFacts.swift.
import Foundation

@main struct ClientInsightFactsTests {
    static func main() {
        // Display order never moves: tokens, events, then the cut's count.
        let panels = ClientInsightFacts.panels(
            tokens: 26_600_000_000,
            events: 124_003,
            count: 68,
            countLabel: "Models",
            formatCompact: { "\($0)" }
        )
        precondition(panels.count == 3, "three panels, not a strip")
        precondition(panels[0].label == "Tokens", "first panel is tokens")
        precondition(panels[0].value == "26600000000", "tokens use the compact formatter")
        precondition(panels[1].label == "Events", "second panel is events")
        precondition(panels[1].value == UInt64(124_003).formatted(), "events use grouped formatting")
        precondition(panels[2].label == "Models", "third panel carries the cut label")
        precondition(panels[2].value == "68", "count is plain")

        // Every Insights cut keeps the same order; only the third label moves.
        for label in ["Models", "Harnesses", "Days"] {
            let cut = ClientInsightFacts.panels(
                tokens: 0, events: 0, count: 0, countLabel: label, formatCompact: { _ in "0" }
            )
            precondition(cut.map { $0.label } == ["Tokens", "Events", label], "cut label \(label)")
            precondition(cut.map { $0.value } == ["0", UInt64(0).formatted(), "0"], "zero state")
        }

        print("ClientInsightFactsTests passed")
    }
}
