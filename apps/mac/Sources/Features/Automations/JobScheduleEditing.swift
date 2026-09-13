// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Labels shared by automation and workflow schedule pickers.
enum JobScheduleCopy {
    static let weekdayNames = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]
    static let weekdayShort = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    static let intervalPresets = [15, 30, 60, 120, 360, 720, 1440]

    static func intervalLabel(_ seconds: UInt64) -> String {
        if seconds % 60 != 0 { return "\(seconds) seconds" }
        return intervalPresetLabel(Int(seconds / 60))
    }

    static func intervalPresetLabel(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// Frequency fields both job editors write. Schedule values stay exact until
/// a picker is touched, so a 90-second interval does not round to a minute.
protocol JobScheduleEditing {
    var scheduleKind: ScheduleKind { get set }
    var intervalMinutes: String { get set }
    var intervalSeconds: UInt64 { get set }
    var intervalTouched: Bool { get set }
    var hour: Int { get set }
    var minute: Int { get set }
    var weekday: Int { get set }
    var weeklyDays: Int { get set }
    var weeklyDayEdited: Bool { get set }
    var customDays: Int { get set }
}

extension JobScheduleEditing {
    var intervalCurrentSeconds: UInt64 {
        if !intervalTouched, intervalSeconds > 0 {
            return max(intervalSeconds, 60)
        }
        let minutes = min(UInt64(intervalMinutes) ?? 60, UInt64.max / 60)
        return max(minutes * 60, 60)
    }

    var intervalMenuMinutes: [Int] {
        let seconds = intervalCurrentSeconds
        guard seconds % 60 == 0 else { return JobScheduleCopy.intervalPresets }
        let current = max(1, Int(seconds / 60))
        if JobScheduleCopy.intervalPresets.contains(current) { return JobScheduleCopy.intervalPresets }
        return (JobScheduleCopy.intervalPresets + [current]).sorted()
    }

    var builtSchedule: AutomationSchedule {
        switch scheduleKind {
        case .once:
            return AutomationSchedule(kind: .once)
        case .interval:
            return AutomationSchedule(kind: .interval, everySeconds: intervalCurrentSeconds)
        case .daily:
            return AutomationSchedule(kind: .daily, hour: hour, minute: minute)
        case .weekdays:
            return AutomationSchedule(
                kind: .weekdays, hour: hour, minute: minute,
                weekdays: AutomationSchedule.weekdaysMask
            )
        case .weekly:
            return AutomationSchedule(
                kind: .weekly, hour: hour, minute: minute, weekday: weekday,
                weekdays: weeklyDayEdited ? 0 : weeklyDays
            )
        case .custom:
            return AutomationSchedule(
                kind: .custom, hour: hour, minute: minute, weekdays: customDays
            )
        }
    }

    var weeklyDayLabel: String {
        if !weeklyDayEdited, weeklyDays != 0 {
            return (0..<7).compactMap { bit in
                (weeklyDays & (1 << bit)) != 0 ? JobScheduleCopy.weekdayNames[bit] : nil
            }.joined(separator: ", ")
        }
        guard weekday >= 0, weekday < JobScheduleCopy.weekdayNames.count else { return "Day" }
        return JobScheduleCopy.weekdayNames[weekday]
    }

    func weeklyDaySelected(_ day: Int) -> Bool {
        if weeklyDayEdited { return weekday == day }
        if weeklyDays != 0 { return (weeklyDays & (1 << day)) != 0 }
        return weekday == day
    }

    var scheduleValidation: String? {
        if scheduleKind == .custom, (customDays & 0b0111_1111) == 0 {
            return "Pick at least one day for a custom schedule."
        }
        if scheduleKind == .interval, intervalCurrentSeconds < 60 {
            return "An interval must be at least a minute."
        }
        if hour < 0 || hour > 23 || minute < 0 || minute > 59 {
            return "Choose a real hour and minute."
        }
        return nil
    }

    mutating func loadSchedule(_ schedule: AutomationSchedule) {
        scheduleKind = schedule.kind
        intervalTouched = false
        intervalSeconds = schedule.kind == .interval ? schedule.everySeconds : 0
        intervalMinutes = String(max(1, schedule.everySeconds / 60))
        hour = min(max(schedule.hour, 0), 23)
        minute = min(max(schedule.minute, 0), 59)
        weekday = schedule.weekday
        weeklyDayEdited = false
        weeklyDays = schedule.kind == .weekly ? schedule.weekdays & 0b0111_1111 : 0
        if schedule.weekdays != 0 {
            customDays = schedule.weekdays
        } else if schedule.kind == .custom || schedule.kind == .weekdays {
            customDays = AutomationSchedule.weekdaysMask
        } else if schedule.kind == .weekly, schedule.weekday >= 0, schedule.weekday <= 6 {
            customDays = 1 << schedule.weekday
        } else {
            customDays = AutomationSchedule.weekdaysMask
        }
    }

    mutating func resetSchedule() {
        scheduleKind = .once
        intervalMinutes = "60"
        intervalSeconds = 0
        intervalTouched = false
        hour = 9
        minute = 0
        weekday = 0
        weeklyDays = 0
        weeklyDayEdited = false
        customDays = AutomationSchedule.weekdaysMask
    }
}

/// Minutes and no-limit, shared by automations and workflows.
protocol JobBudgetEditing {
    var budgetMinutes: String { get set }
    var noTimeLimit: Bool { get set }
}

extension JobBudgetEditing {
    var budgetSeconds: UInt64? {
        if noTimeLimit { return 0 }
        guard let minutes = UInt64(budgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)), minutes > 0 else {
            return nil
        }
        let product = minutes.multipliedReportingOverflow(by: 60)
        return product.overflow ? nil : product.partialValue
    }

    var budgetValidation: String? {
        budgetSeconds == nil ? "Enter a positive time limit, or choose No limit." : nil
    }

    mutating func loadBudget(seconds: UInt64) {
        noTimeLimit = seconds == 0
        budgetMinutes = noTimeLimit ? "180" : String(max(1, seconds / 60))
    }
}
