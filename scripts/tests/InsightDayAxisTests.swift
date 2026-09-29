// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with InsightDayAxis.swift.
import Foundation
@main struct InsightDayAxisTests {
    static func main() {
        precondition(InsightDayAxis.position("2026-09-04")! - InsightDayAxis.position("2026-09-01")! == 3)
        precondition(InsightDayAxis.position("2024-03-01")! - InsightDayAxis.position("2024-02-28")! == 2)
        precondition(InsightDayAxis.position("2026-02-30") == nil)
        precondition(InsightDayAxis.position("not a day") == nil)
        let domain = InsightDayAxis.domain(["2026-09-01", "2026-09-04"])
        precondition(domain.upperBound - domain.lowerBound == 4)
        precondition(InsightDayAxis.domain([]) == 0...1)
        print("PASS: daily chart gaps, leap days and invalid dates")
    }
}
