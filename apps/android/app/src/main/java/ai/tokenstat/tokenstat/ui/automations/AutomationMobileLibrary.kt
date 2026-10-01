// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

import ai.tokenstat.tokenstat.ui.localization.L10n

data class AutomationTemplate(
    val id: String, val title: String, val prompt: String, val backend: String,
    val schedule: AutomationSchedule, val budgetSeconds: Long,
) {
    fun draft(workspace: String): AutomationEditorDraft = AutomationEditorDraft.blank(workspace, budgetSeconds, backend).copy(
        name = title, prompt = prompt, schedule = ScheduleFields.load(schedule),
    )
}

object AutomationTemplates {
    val suggested = listOf(
        AutomationTemplate("brief", L10n.text("android.automationmobilelibrary.daily_brief.ba6a6869"), L10n.text("android.automationmobilelibrary.summarise_yesterday_s_usage_and_flag_anyth.46ae43e4"), "claude", AutomationSchedule(ScheduleKind.DAILY, hour = 8), 600),
        AutomationTemplate("health", L10n.text("android.automationmobilelibrary.system_health_check.04b44a8a"), L10n.text("android.automationmobilelibrary.check_disk_memory_and_cpu_and_confirm_the.1eeb5edf"), "claude", AutomationSchedule(ScheduleKind.INTERVAL, everySeconds = 3600), 120),
        AutomationTemplate("dependencies", L10n.text("android.automationmobilelibrary.dependency_check.cb31b5a0"), L10n.text("android.automationmobilelibrary.check_for_outdated_or_vulnerable_dependenc.12dfb6f0"), "claude", AutomationSchedule(ScheduleKind.WEEKLY, hour = 9, weekday = 0), 900),
        AutomationTemplate("standup", L10n.text("android.automationmobilelibrary.weekday_standup.26dadcac"), L10n.text("android.automationmobilelibrary.summarise_open_work_and_anything_that_bloc.52f7cb29"), "claude", AutomationSchedule(ScheduleKind.WEEKDAYS, hour = 9, weekdays = WEEKDAYS_MASK), 600),
        AutomationTemplate("release", L10n.text("android.automationmobilelibrary.release.e020e3c6"), L10n.text("android.automationmobilelibrary.ship_a_release_of_this_repository_1_read_h.b379d887").trimIndent(), "claude", AutomationSchedule(ScheduleKind.ONCE), 1800),
    )
}

enum class AutomationMobileOrder(val label: String) {
    NAME(L10n.text("android.automationmobilelibrary.name.dcd1d522")), SCHEDULE(L10n.text("android.automationmobilelibrary.schedule.f4830a1d")), NEXT_RUN(L10n.text("android.automationmobilelibrary.next_run.b3c0ab96")), LAST_RUN(L10n.text("android.automationmobilelibrary.last_run.512a4821"));
    fun sorted(jobs: List<AutomationJob>): List<AutomationJob> = jobs.sortedWith { left, right ->
        val primary = when (this) {
            NAME -> left.name.lowercase().compareTo(right.name.lowercase())
            SCHEDULE -> left.schedule.summary.compareTo(right.schedule.summary, ignoreCase = true)
            NEXT_RUN -> compareDates(left.nextRunAtMs, right.nextRunAtMs, false)
            LAST_RUN -> compareDates(left.lastRunAtMs, right.lastRunAtMs, true)
        }
        if (primary != 0) primary else {
            val names = left.name.lowercase().compareTo(right.name.lowercase())
            if (names != 0) names else left.id.compareTo(right.id)
        }
    }
    private fun compareDates(left: Long?, right: Long?, newest: Boolean): Int = when {
        left == null && right == null -> 0
        left == null -> 1
        right == null -> -1
        newest -> right.compareTo(left)
        else -> left.compareTo(right)
    }
}
