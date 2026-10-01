// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum AutomationMobileOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case schedule = "Schedule"
    case nextRun = "Next run"
    case lastRun = "Last run"
    var id: Self { self }

    func sorted(_ jobs: [Automation]) -> [Automation] {
        jobs.sorted { left, right in
            let comparison: ComparisonResult
            switch self {
            case .name: comparison = left.name.localizedStandardCompare(right.name)
            case .schedule: comparison = left.schedule.summary.localizedStandardCompare(right.schedule.summary)
            case .nextRun: comparison = compare(left.nextRunAtMs, right.nextRunAtMs, newestFirst: false)
            case .lastRun: comparison = compare(left.lastRunAtMs, right.lastRunAtMs, newestFirst: true)
            }
            if comparison != .orderedSame { return comparison == .orderedAscending }
            let names = left.name.localizedStandardCompare(right.name)
            return names == .orderedSame ? left.id < right.id : names == .orderedAscending
        }
    }
    private func compare(_ left: Int64?, _ right: Int64?, newestFirst: Bool) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (left?, right?):
            if left == right { return .orderedSame }
            return (newestFirst ? left > right : left < right) ? .orderedAscending : .orderedDescending
        }
    }
}
