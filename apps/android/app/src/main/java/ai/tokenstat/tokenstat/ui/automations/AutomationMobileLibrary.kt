// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

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
        AutomationTemplate("brief", "Daily brief", "Summarise yesterday's usage and flag anything that needs attention.", "claude", AutomationSchedule(ScheduleKind.DAILY, hour = 8), 600),
        AutomationTemplate("health", "System health check", "Check disk, memory and CPU, and confirm the tokenstat daemon is running. Report anything abnormal.", "sh", AutomationSchedule(ScheduleKind.INTERVAL, everySeconds = 3600), 120),
        AutomationTemplate("dependencies", "Dependency check", "Check for outdated or vulnerable dependencies (npm audit and the package managers this project uses) and summarise what needs a bump.", "sh", AutomationSchedule(ScheduleKind.WEEKLY, hour = 9, weekday = 0), 900),
        AutomationTemplate("standup", "Weekday standup", "Summarise open work and anything that blocked progress yesterday. Keep it short.", "claude", AutomationSchedule(ScheduleKind.WEEKDAYS, hour = 9, weekdays = WEEKDAYS_MASK), 600),
        AutomationTemplate("release", "Release", """
Ship a release of this repository.

1. Read how this repo versions itself (workspace manifests, lockfile,  app marketing version, changelog if one exists). Bump to the next  version the same way the last release did. Refresh the lockfile if  this project requires it.
2. Commit the bump only. Match this repository's commit style  (CONTRIBUTING, commitlint, or recent subjects). Do not mix other  work into the bump.
3. Push the branch to GitHub. Do not force. Do not amend published  history.
4. Wait for CI on that commit. Poll until it finishes. If anything  fails, read the failing job, fix it, commit the fix, push, and wait  again. Repeat until CI is green.
5. Only then create an annotated version tag on that commit and push  the tag. Do not tag a red commit. Do not move an existing tag.

If the working tree is dirty with unrelated changes, stop and say so.  If you cannot see CI, say what you could not check and stop before  the tag.
""".trimIndent(), "claude", AutomationSchedule(ScheduleKind.ONCE), 1800),
    )
}

enum class AutomationMobileOrder(val label: String) {
    NAME("Name"), SCHEDULE("Schedule"), NEXT_RUN("Next run"), LAST_RUN("Last run");
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
