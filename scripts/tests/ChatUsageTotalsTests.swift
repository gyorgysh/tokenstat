// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatCostMeter.swift.
import SwiftUI

// Presentation dependencies only; arithmetic and Codable are production code.
enum Theme {
    enum Space { static let s: CGFloat = 8; static let m: CGFloat = 12 }
    static let caption = Font.caption
    static let callout = Font.callout
    static let accent = Color.orange
    static let secondary = Color.secondary
    static let accentSoft = Color.orange.opacity(0.1)
    static let panel = Color.clear
    static let border = Color.clear
}

@main
struct ChatUsageTotalsTests {
    static func main() throws {
        var normal = ChatUsageTotals.zero
        assert(normal.add(.init(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, cost: 0.25)))
        assert(normal.input == 10 && normal.output == 20 && normal.cache == 70 && normal.cost == 0.25)
        let maximum = ChatUsageTotals(input: .max, output: .max, cacheRead: .max, cacheWrite: .max, cost: 1)
        assert(maximum.cache == Decimal(string: "36893488147419103230")!)
        assert(!maximum.isEmpty && maximum.isValid)
        for increment in [
            ChatUsageTotals(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0),
            ChatUsageTotals(input: 0, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0),
            ChatUsageTotals(input: 0, output: 0, cacheRead: 1, cacheWrite: 0, cost: 0),
            ChatUsageTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 1, cost: 0)
        ] {
            var candidate = maximum
            assert(!candidate.add(increment))
            assert(candidate == maximum)
        }
        for cost in [-1.0, Double.infinity, Double.nan] {
            var candidate = normal
            assert(!candidate.add(.init(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, cost: cost)))
            assert(candidate == normal)
        }
        var costLimit = ChatUsageTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: .greatestFiniteMagnitude)
        let before = costLimit
        assert(!costLimit.add(before) && costLimit == before)
        let encoded = try JSONEncoder().encode(maximum)
        let decoded = try JSONDecoder().decode(ChatUsageTotals.self, from: encoded)
        assert(decoded == maximum)
        print("PASS: production usage totals arithmetic, exact cache sum and wire round trip")
    }
}
