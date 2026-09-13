// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Shared automation fields for Mac and mobile. Schedule values stay exact
/// until a picker is touched, so a 90-second interval does not round to a minute.
struct AutomationEditorDraft: Codable, Equatable, Sendable {
    enum Invalid: LocalizedError {
        case fields(String)
        var errorDescription: String? { switch self { case let .fields(message): message } }
    }

    var name: String
    var prompt: String
    var workspaceID: String
    var backend: String
    var model: String
    var effort: String
    var scheduleKind: ScheduleKind
    var intervalMinutes: String
    var intervalSeconds: UInt64
    var intervalTouched: Bool
    var hour: Int
    var minute: Int
    var weekday: Int
    var weeklyDays: Int
    var weeklyDayEdited: Bool
    var customDays: Int
    var budgetMinutes: String
    var noTimeLimit: Bool

    static let weekdayNames = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]
    static let weekdayShort = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    static let intervalPresets = [15, 30, 60, 120, 360, 720, 1440]

    enum CodingKeys: String, CodingKey {
        case name, prompt, backend, model, effort, scheduleKind, intervalMinutes, intervalSeconds
        case intervalTouched, hour, minute, weekday, weeklyDays, weeklyDayEdited, customDays
        case budgetMinutes, noTimeLimit
        case workspaceID = "workspaceId"
    }

    init(workspaceID: String, budgetSeconds: UInt64 = 10_800, backend: String = "") {
        name = ""
        prompt = ""
        self.workspaceID = workspaceID
        self.backend = backend
        model = ""
        effort = ""
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
        noTimeLimit = budgetSeconds == 0
        budgetMinutes = noTimeLimit ? "180" : String(max(1, budgetSeconds / 60))
    }

    init(_ job: Automation) {
        name = job.name
        prompt = job.prompt
        workspaceID = job.workspaceID
        backend = job.backend
        model = TodoCard.cleanModelID(job.model ?? "")
        effort = job.effort ?? ""
        scheduleKind = job.schedule.kind
        intervalTouched = false
        intervalSeconds = job.schedule.kind == .interval ? job.schedule.everySeconds : 0
        intervalMinutes = String(max(1, job.schedule.everySeconds / 60))
        hour = min(max(job.schedule.hour, 0), 23)
        minute = min(max(job.schedule.minute, 0), 59)
        weekday = job.schedule.weekday
        weeklyDayEdited = false
        weeklyDays = job.schedule.kind == .weekly ? job.schedule.weekdays & 0b0111_1111 : 0
        if job.schedule.weekdays != 0 {
            customDays = job.schedule.weekdays
        } else if job.schedule.kind == .custom || job.schedule.kind == .weekdays {
            customDays = AutomationSchedule.weekdaysMask
        } else if job.schedule.kind == .weekly, job.schedule.weekday >= 0, job.schedule.weekday <= 6 {
            customDays = 1 << job.schedule.weekday
        } else {
            customDays = AutomationSchedule.weekdaysMask
        }
        noTimeLimit = job.budgetSeconds == 0
        budgetMinutes = noTimeLimit ? "180" : String(max(1, job.budgetSeconds / 60))
    }

    var intervalCurrentSeconds: UInt64 {
        if !intervalTouched, intervalSeconds > 0 {
            return max(intervalSeconds, 60)
        }
        let minutes = min(UInt64(intervalMinutes) ?? 60, UInt64.max / 60)
        return max(minutes * 60, 60)
    }

    var intervalMenuMinutes: [Int] {
        let seconds = intervalCurrentSeconds
        guard seconds % 60 == 0 else { return Self.intervalPresets }
        let current = max(1, Int(seconds / 60))
        if Self.intervalPresets.contains(current) { return Self.intervalPresets }
        return (Self.intervalPresets + [current]).sorted()
    }

    var budgetSeconds: UInt64? {
        if noTimeLimit { return 0 }
        guard let minutes = UInt64(budgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)), minutes > 0 else {
            return nil
        }
        let product = minutes.multipliedReportingOverflow(by: 60)
        return product.overflow ? nil : product.partialValue
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
                (weeklyDays & (1 << bit)) != 0 ? Self.weekdayNames[bit] : nil
            }.joined(separator: ", ")
        }
        guard weekday >= 0, weekday < Self.weekdayNames.count else { return "Day" }
        return Self.weekdayNames[weekday]
    }

    func weeklyDaySelected(_ day: Int) -> Bool {
        if weeklyDayEdited { return weekday == day }
        if weeklyDays != 0 { return (weeklyDays & (1 << day)) != 0 }
        return weekday == day
    }

    var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this job a name."
        }
        if name.utf8.count > 4096 {
            return "Shorten the name to 4 KiB or less."
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write what the agent should do."
        }
        if prompt.utf8.count > 1024 * 1024 {
            return "Shorten the prompt to 1 MiB or less."
        }
        if workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a folder for this job."
        }
        if backend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose an agent for this job."
        }
        if scheduleKind == .custom, (customDays & 0b0111_1111) == 0 {
            return "Pick at least one day for a custom schedule."
        }
        if scheduleKind == .interval, intervalCurrentSeconds < 60 {
            return "An interval must be at least a minute."
        }
        if hour < 0 || hour > 23 || minute < 0 || minute > 59 {
            return "Choose a real hour and minute."
        }
        if budgetSeconds == nil {
            return "Enter a positive time limit, or choose No limit."
        }
        return nil
    }

    func matches(_ job: Automation) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) == job.name
            && prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                == job.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            && workspaceID == job.workspaceID
            && backend == job.backend
            && TodoCard.cleanModelID(model) == TodoCard.cleanModelID(job.model ?? "")
            && effort.trimmingCharacters(in: .whitespacesAndNewlines)
                == (job.effort ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            && builtSchedule == job.schedule
            && budgetSeconds == job.budgetSeconds
    }

    func makeJob(
        id: String,
        enabled: Bool,
        lastRunAtMs: Int64? = nil,
        lastRunID: String? = nil,
        revision: UInt64 = 0
    ) throws -> Automation {
        guard validation == nil, let budgetSeconds else {
            throw Invalid.fields(validation ?? "Check this job's settings.")
        }
        let cleaned = TodoCard.cleanModelID(model)
        return Automation(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            backend: backend,
            model: cleaned.isEmpty ? nil : cleaned,
            effort: effort.isEmpty ? nil : effort,
            workspaceID: workspaceID,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: builtSchedule,
            budgetSeconds: budgetSeconds,
            enabled: enabled,
            lastRunAtMs: lastRunAtMs,
            nextRunAtMs: nil,
            lastRunID: lastRunID,
            revision: revision
        )
    }

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
