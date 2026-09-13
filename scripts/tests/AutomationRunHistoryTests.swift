// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutomationRunHistory.swift.
import Foundation

struct SampleRun {
    var id: String
    var startedAtMs: Int64
    var isRunning: Bool
}

@main struct AutomationRunHistoryTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }

        let live = SampleRun(id: "live", startedAtMs: 1_000, isRunning: true)
        let newest = SampleRun(id: "b", startedAtMs: 900, isRunning: false)
        let older = SampleRun(id: "a", startedAtMs: 800, isRunning: false)
        let oldest = SampleRun(id: "z", startedAtMs: 700, isRunning: false)
        let sameTime = SampleRun(id: "m", startedAtMs: 900, isRunning: false)
        let mixed = [older, live, newest, oldest, sameTime]

        let ordered = AutomationRunHistory.ordered(
            mixed, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        )
        check(ordered.map(\.id) == ["live", "m", "b", "a", "z"], "live first, then newest, then id")
        check(
            AutomationRunHistory.latest(
                mixed, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
            )?.id == "live",
            "latest is the live run"
        )
        check(
            AutomationRunHistory.latest(
                [oldest, older], id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
            )?.id == "a",
            "without a live run, latest is the newest completed"
        )

        let preview = AutomationRunHistory.preview(
            mixed, id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        )
        check(preview.map(\.id) == ["live", "m", "b", "a", "z"], "five fits in the preview")
        check(AutomationRunHistory.showsAllRuns(5) == false, "preview is the whole list")
        check(AutomationRunHistory.showsAllRuns(6), "a sixth run needs All runs")

        var many: [SampleRun] = [live]
        for index in 1...24 {
            many.append(SampleRun(id: "old-\(index)", startedAtMs: Int64(900 - index), isRunning: false))
        }
        check(many.count == 25, "one live and twenty-four completed")
        let page = AutomationRunHistory.page(
            many, shown: AutomationRunHistory.pageSize,
            id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        )
        check(page.count == 20, "first page is twenty")
        check(page.first?.id == "live", "the live run stays on the first page")
        check(page.contains(where: { $0.id == "old-24" }) == false, "the oldest completed wait")
        check(AutomationRunHistory.remaining(total: 25, shown: 20) == 5, "five earlier runs")
        let next = AutomationRunHistory.page(
            many, shown: 40,
            id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        )
        check(next.count == 25, "later page is just the rest")
        check(AutomationRunHistory.remaining(total: 25, shown: 40) == 0, "nothing left")
        check(AutomationRunHistory.page(
            many, shown: 0,
            id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        ).isEmpty, "zero shown is empty")
        check(AutomationRunHistory.preview(
            [SampleRun](), id: \.id, startedAtMs: \.startedAtMs, isLive: \.isRunning
        ).isEmpty, "no runs")

        print("AutomationRunHistoryTests passed")
    }
}
