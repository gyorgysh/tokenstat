// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutomationMobileOrdering.swift AutomationTemplates.swift.
import Foundation
enum ScheduleKind: String, Hashable, Sendable { case once, interval, daily, weekdays, weekly, custom }
struct AutomationSchedule: Hashable, Sendable {
    var kind: ScheduleKind
    var everySeconds: UInt64 = 0
    var hour = 9
    var minute = 0
    var weekday = 0
    var weekdays = 0
    static let weekdaysMask = 31
    var summary: String { kind.rawValue }
}
struct Automation {
    var id: String
    var name = "same"
    var schedule = AutomationSchedule(kind: .once)
    var nextRunAtMs: Int64?
    var lastRunAtMs: Int64?
}
@main struct AutomationMobileOrderingTests {
    static func main() {
        let rows = [Automation(id: "z"), Automation(id: "b", nextRunAtMs: .max, lastRunAtMs: .min),
                    Automation(id: "a", nextRunAtMs: .max, lastRunAtMs: .max)]
        assert(AutomationMobileOrder.nextRun.sorted(rows).map(\.id) == ["a", "b", "z"])
        assert(AutomationMobileOrder.lastRun.sorted(rows).map(\.id) == ["a", "b", "z"])
        assert(AutomationMobileOrder.name.sorted(rows).map(\.id) == ["a", "b", "z"])
        let templates = AutomationTemplate.suggested
        assert(templates.count == 5 && Set(templates.map(\.id)).count == 5)
        assert(templates.allSatisfy { $0.backendID != "sh" },
               "Suggested natural-language instructions must run through an agent, not a shell")
        assert(templates.first { $0.title == "Daily brief" }?.schedule.hour == 8)
        assert(templates.first { $0.title == "Weekday standup" }?.schedule.weekdays == 31)
        assert(templates.first { $0.title == "System health check" }?.schedule.everySeconds == 3600)
        assert(templates.first { $0.title == "Release" }?.budgetSeconds == 1800)
        print("Automation mobile ordering and templates passed")
    }
}
