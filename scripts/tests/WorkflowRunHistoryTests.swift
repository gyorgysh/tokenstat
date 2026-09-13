// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutomationRunHistory.swift.
import Foundation

struct WorkflowRun: Identifiable {
    var id: String
    var startedAtMs: Int64
    var isLive: Bool
}

@main
struct WorkflowRunHistoryTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }
        func run(_ id: String, started: Int64, live: Bool = false) -> WorkflowRun {
            WorkflowRun(id: id, startedAtMs: started, isLive: live)
        }
        // Live first, then newest. A missing run never stands in for another.
        let mixed = [
            run("old", started: 100),
            run("live", started: 50, live: true),
            run("new", started: 300),
        ]
        let ordered = AutomationRunHistory.ordered(
            mixed, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
        )
        check(ordered.map(\.id) == ["live", "new", "old"], "live first, then newest")
        check(
            AutomationRunHistory.latest(
                mixed, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
            )?.id == "live",
            "latest is the live run"
        )
        // Preview of five, pages of twenty, honest leftovers.
        var many: [WorkflowRun] = [run("live", started: 10_000, live: true)]
        for index in 1...26 {
            many.append(run("run-\(index)", started: Int64(10_000 - index * 100)))
        }
        check(many.count == 27, "fixture breadth")
        let preview = AutomationRunHistory.preview(
            many, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
        )
        check(preview.count == 5, "preview of five")
        check(preview.first?.id == "live", "preview leads with live")
        check(AutomationRunHistory.showsAllRuns(many.count), "twenty-seven needs history")
        check(!AutomationRunHistory.showsAllRuns(5), "five needs no history")
        let page = AutomationRunHistory.page(
            many, shown: 20, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
        )
        check(page.count == 20, "page of twenty")
        check(AutomationRunHistory.remaining(total: many.count, shown: 20) == 7, "leftover of seven")
        check(AutomationRunHistory.remaining(total: many.count, shown: 27) == 0, "no leftover")
        check(AutomationRunHistory.page(
            many, shown: 40, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isLive
        ).count == 27, "overlarge page clamps")
        print("WorkflowRunHistoryTests passed")
    }
}
