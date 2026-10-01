// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A suggested setup on the Automations screen, pre-filling the sheet.
struct AutomationTemplate: Identifiable, Hashable, Sendable {
    var id: String { title }
    var title: String
    var subtitle: String
    var symbol: String
    var name: String
    var prompt: String
    var backendID: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
}

extension AutomationTemplate {
    static let suggested: [AutomationTemplate] = [
        AutomationTemplate(
            title: L10n.text("apple.automationtemplates.daily_brief.ba6a6869"),
            subtitle: L10n.text("apple.automationtemplates.every_morning_at_8_00.5c6ddc01"),
            symbol: "sunrise",
            name: L10n.text("apple.automationtemplates.daily_brief.ba6a6869"),
            prompt: L10n.text("apple.automationtemplates.summarise_yesterday_s_usage_and_flag_anyth.46ae43e4"),
            backendID: "claude",
            schedule: AutomationSchedule(kind: .daily, everySeconds: 0, hour: 8, minute: 0, weekday: 0),
            budgetSeconds: 600
        ),
        AutomationTemplate(
            title: L10n.text("apple.automationtemplates.system_health_check.04b44a8a"),
            subtitle: L10n.text("apple.automationtemplates.every_hour.a4bac465"),
            symbol: "heart.text.square",
            name: L10n.text("apple.automationtemplates.system_health_check.04b44a8a"),
            prompt: L10n.text("apple.automationtemplates.check_disk_memory_and_cpu_and_confirm_the.1eeb5edf"),
            backendID: "claude",
            schedule: AutomationSchedule(kind: .interval, everySeconds: 3600, hour: 0, minute: 0, weekday: 0),
            budgetSeconds: 120
        ),
        AutomationTemplate(
            title: L10n.text("apple.automationtemplates.dependency_check.cb31b5a0"),
            subtitle: L10n.text("apple.automationtemplates.every_week.1b7e1851"),
            symbol: "shippingbox",
            name: L10n.text("apple.automationtemplates.dependency_check.cb31b5a0"),
            prompt: L10n.text("apple.automationtemplates.check_for_outdated_or_vulnerable_dependenc.12dfb6f0"),
            backendID: "claude",
            schedule: AutomationSchedule(kind: .weekly, hour: 9, minute: 0, weekday: 0),
            budgetSeconds: 900
        ),
        AutomationTemplate(
            title: L10n.text("apple.automationtemplates.weekday_standup.26dadcac"),
            subtitle: L10n.text("apple.automationtemplates.weekdays_at_9_00.745106c2"),
            symbol: "person.3",
            name: L10n.text("apple.automationtemplates.weekday_standup.26dadcac"),
            prompt: L10n.text("apple.automationtemplates.summarise_open_work_and_anything_that_bloc.52f7cb29"),
            backendID: "claude",
            schedule: AutomationSchedule(
                kind: .weekdays, hour: 9, minute: 0,
                weekdays: AutomationSchedule.weekdaysMask
            ),
            budgetSeconds: 600
        ),
        AutomationTemplate(
            title: L10n.text("apple.automationtemplates.release.e020e3c6"),
            subtitle: L10n.text("apple.automationtemplates.once_when_you_run_it.373a34a3"),
            symbol: "tag",
            name: L10n.text("apple.automationtemplates.release.e020e3c6"),
            prompt: releasePrompt,
            backendID: "claude",
            schedule: AutomationSchedule(kind: .once),
            budgetSeconds: 1800
        ),
    ]

    static let releasePrompt = L10n.text("apple.automationtemplates.ship_a_release_of_this_repository_1_read_h.ad0794e7")
}
