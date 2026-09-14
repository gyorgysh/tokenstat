// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.tasks.RunAcceptance
import ai.tokenstat.tokenstat.ui.tasks.RunHistory
import ai.tokenstat.tokenstat.ui.tasks.RunRef
import ai.tokenstat.tokenstat.ui.tasks.TaskBoardAttention
import ai.tokenstat.tokenstat.ui.tasks.TaskBoardFilter
import ai.tokenstat.tokenstat.ui.tasks.TaskBoardFolder
import ai.tokenstat.tokenstat.ui.tasks.TaskCard
import ai.tokenstat.tokenstat.ui.tasks.TaskDelegate
import ai.tokenstat.tokenstat.ui.tasks.TaskEditorDraft
import ai.tokenstat.tokenstat.ui.tasks.TaskResultRoute
import ai.tokenstat.tokenstat.ui.tasks.TaskRunOutcome
import ai.tokenstat.tokenstat.ui.tasks.TaskRunPlacement
import ai.tokenstat.tokenstat.ui.tasks.acceptTaskRun
import ai.tokenstat.tokenstat.ui.tasks.cleanModelID
import ai.tokenstat.tokenstat.ui.tasks.taskRunReadiness
import ai.tokenstat.tokenstat.ui.tasks.FolderRef
import ai.tokenstat.tokenstat.ui.automations.AutomationEditorDraft
import ai.tokenstat.tokenstat.ui.automations.AutomationJob
import ai.tokenstat.tokenstat.ui.automations.AutomationSchedule
import ai.tokenstat.tokenstat.ui.automations.BudgetFields
import ai.tokenstat.tokenstat.ui.automations.HostScheduleClock
import ai.tokenstat.tokenstat.ui.automations.JobScheduleCopy
import ai.tokenstat.tokenstat.ui.automations.QueueValidation
import ai.tokenstat.tokenstat.ui.automations.ScheduleFields
import ai.tokenstat.tokenstat.ui.automations.ScheduleKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the authoring-wave pure logic to the same answers the Apple
/// client's Swift originals produce.
class AuthoringLogicTest {

    private fun card(
        id: String = "c1",
        title: String = "Title",
        notes: String = "prompt",
        column: String = "backlog",
        order: Long = 0,
        backend: String = "codex",
        workspaceID: String = "w1",
        priority: String = "normal",
        budget: Long = 10_800,
        delegate: TaskDelegate? = null,
        created: Long = 1,
    ) = TaskCard(
        id = id, revision = 3, title = title, notes = notes, column = column,
        order = order, priority = priority, backend = backend,
        workspaceID = workspaceID, budgetSeconds = budget,
        createdAtMs = created, updatedAtMs = created, delegate = delegate,
    )

    @Test
    fun cleanModelIDStripsLabels() {
        assertEquals("gpt-5", cleanModelID("gpt-5\tGPT 5"))
        assertEquals("claude-opus-4-1", cleanModelID("claude-opus-4-1Claude Opus"))
        assertEquals("plain", cleanModelID("  plain  "))
    }

    @Test
    fun taskDraftValidation() {
        assertEquals("Give this task a title.", TaskEditorDraft().validation)
        assertEquals(
            "Enter a positive time limit, or choose No limit.",
            TaskEditorDraft(title = "t", budgetValue = "0").validation,
        )
        assertEquals(
            "Choose minutes or seconds for the time limit.",
            TaskEditorDraft(title = "t", budgetUnit = "hours").validation,
        )
        assertEquals(
            "Choose a task priority.",
            TaskEditorDraft(title = "t", priority = "urgent").validation,
        )
        assertNull(TaskEditorDraft(title = "t").validation)
        assertNull(TaskEditorDraft(title = "t", noTimeLimit = true, budgetValue = "").validation)
    }

    @Test
    fun taskDraftBudgetSeconds() {
        assertEquals(10_800L, TaskEditorDraft(title = "t").budgetSeconds)
        assertEquals(90L, TaskEditorDraft(title = "t", budgetValue = "90", budgetUnit = "seconds").budgetSeconds)
        assertEquals(0L, TaskEditorDraft(title = "t", noTimeLimit = true).budgetSeconds)
        assertNull(TaskEditorDraft(title = "t", budgetValue = "abc").budgetSeconds)
    }

    @Test
    fun taskDraftMatches() {
        val card = card()
        assertTrue(TaskEditorDraft.fromCard(card).matches(card))
        assertTrue(!TaskEditorDraft.fromCard(card).copy(title = "Other").matches(card))
        assertTrue(!TaskEditorDraft.fromCard(card).copy(budgetValue = "1").matches(card))
    }

    @Test
    fun boardFilterScopesAndSearch() {
        val cards = listOf(
            card(id = "a", title = "Fix login", workspaceID = "w1"),
            card(id = "b", title = "Fix logout", workspaceID = ""),
            card(id = "c", title = "Docs", workspaceID = "w2", column = "archive"),
        )
        assertEquals(listOf("a"), TaskBoardFilter(folder = TaskBoardFolder.Folder("w1")).visible(cards).map { it.id })
        assertEquals(listOf("b"), TaskBoardFilter(folder = TaskBoardFolder.Uncategorized).visible(cards).map { it.id })
        assertEquals(listOf("c"), TaskBoardFilter(archived = true).visible(cards).map { it.id })
        assertEquals(
            listOf("a"),
            TaskBoardFilter(query = "fix LOGIN").visible(cards).map { it.id },
        )
        assertEquals(
            emptyList<String>(),
            TaskBoardFilter(query = "fix missing").visible(cards).map { it.id },
        )
    }

    @Test
    fun boardFilterAttention() {
        val running = card(id = "r", delegate = TaskDelegate(status = "running"))
        val failed = card(id = "f", delegate = TaskDelegate(status = "error"))
        val hot = card(id = "h", priority = "high")
        val plain = card(id = "p")
        val cards = listOf(running, failed, hot, plain)
        assertEquals(listOf("r"), TaskBoardFilter(attention = TaskBoardAttention.RUNNING).visible(cards).map { it.id })
        assertEquals(listOf("f"), TaskBoardFilter(attention = TaskBoardAttention.NEEDS_ATTENTION).visible(cards).map { it.id })
        assertEquals(listOf("h"), TaskBoardFilter(attention = TaskBoardAttention.HIGH_PRIORITY).visible(cards).map { it.id })
    }

    @Test
    fun boardFilterOrdering() {
        val cards = listOf(
            card(id = "old", order = 0, created = 1),
            card(id = "new", order = 1, created = 9),
        )
        assertEquals(listOf("old", "new"), TaskBoardFilter().visible(cards).map { it.id })
        assertEquals(listOf("new", "old"), TaskBoardFilter(newestFirst = true).visible(cards).map { it.id })
    }

    @Test
    fun runReadiness() {
        assertEquals(
            "Assign a folder before running this task.",
            taskRunReadiness(card(workspaceID = ""), emptyList()),
        )
        assertEquals(
            "Choose an agent before running this task.",
            taskRunReadiness(card(backend = ""), listOf(FolderRef("w1", "Web", true))),
        )
        assertEquals(
            "Write a prompt before running this task.",
            taskRunReadiness(card(title = "  ", notes = "  ", backend = "codex"), listOf(FolderRef("w1", "Web", true))),
        )
        assertEquals(
            "This folder is no longer available on the computer.",
            taskRunReadiness(card(), listOf(FolderRef("w1", "Web", false))),
        )
        assertNull(taskRunReadiness(card(), listOf(FolderRef("w1", "Web", true))))
    }

    @Test
    fun acceptRunRules() {
        val submission = Triple("op-1", "c1", TaskRunPlacement.BACKGROUND)
        val accepted = acceptTaskRun(
            TaskRunOutcome(operationID = "op-1", cardID = "c1", runID = "r1", hasRun = true),
            submission.first, submission.second,
        )
        assertTrue(accepted is RunAcceptance.Accepted)
        // A different operation id never confirms: the original run stays
        // the authoritative result.
        assertTrue(
            acceptTaskRun(
                TaskRunOutcome(operationID = "op-2", cardID = "c1", runID = "r2", hasRun = true),
                submission.first, submission.second,
            ) is RunAcceptance.Rejected,
        )
        // Accepted but not recorded yet: check again, do not resend.
        assertTrue(
            acceptTaskRun(
                TaskRunOutcome(operationID = "op-1", cardID = "c1", card = card()),
                submission.first, submission.second,
            ) is RunAcceptance.Pending,
        )
        // No card and no run: the task was deleted before the request
        // could start, and no run was launched.
        assertTrue(
            acceptTaskRun(
                TaskRunOutcome(operationID = "op-1", cardID = "c1"),
                submission.first, submission.second,
            ) is RunAcceptance.Rejected,
        )
    }

    @Test
    fun resultRouteReview() {
        val ready = TaskResultRoute(runID = "r", workspaceID = "w", folderName = "Web", hostName = "Mac")
        assertTrue(ready.canReviewWorkspace)
        assertNull(ready.reviewMessage())
        val bare = TaskResultRoute(runID = "r", workspaceID = "", hostName = "Mac")
        assertEquals(
            "This task has no folder. Assign one to review files and history.",
            bare.reviewMessage(),
        )
        assertEquals("Uncategorized", bare.folderLabel)
        val gone = TaskResultRoute(runID = "r", workspaceID = "w", hostName = "Mac", folderMissing = true)
        assertEquals(
            "This folder is no longer available on Mac.",
            gone.reviewMessage(),
        )
        assertTrue(ready.preservesRun("r"))
        assertTrue(!ready.preservesRun("other"))
    }

    @Test
    fun scheduleSummaries() {
        assertEquals("once, when you run it", AutomationSchedule(ScheduleKind.ONCE).summary)
        assertEquals("every 1 hour", AutomationSchedule(ScheduleKind.INTERVAL, everySeconds = 3600).summary)
        assertEquals("every 30 minutes", AutomationSchedule(ScheduleKind.INTERVAL, everySeconds = 1800).summary)
        assertEquals("daily at 9:05", AutomationSchedule(ScheduleKind.DAILY, hour = 9, minute = 5).summary)
        assertEquals("weekdays at 9:00", AutomationSchedule(ScheduleKind.WEEKDAYS, hour = 9, minute = 0).summary)
        assertEquals(
            "Monday at 9:00",
            AutomationSchedule(ScheduleKind.WEEKLY, hour = 9, minute = 0, weekday = 0).summary,
        )
        assertEquals(
            "Mon, Wed at 9:00",
            AutomationSchedule(ScheduleKind.CUSTOM, hour = 9, minute = 0, weekdays = 0b101).summary,
        )
    }

    @Test
    fun scheduleBuildStaysExactUntilTouched() {
        // A 90-second interval survives a load untouched.
        val loaded = ScheduleFields.load(AutomationSchedule(ScheduleKind.INTERVAL, everySeconds = 90))
        assertEquals(90L, loaded.builtSchedule.everySeconds)
        assertNull(loaded.validation)
        // Touching the picker rounds through whole minutes, minimum 60.
        val touched = loaded.copy(intervalMinutes = "90", intervalTouched = true)
        assertEquals(5400L, touched.builtSchedule.everySeconds)
        // Weekly keeps the host bitset until a day is picked.
        val weekly = ScheduleFields.load(AutomationSchedule(ScheduleKind.WEEKLY, weekday = 2, weekdays = 0b101))
        assertEquals("Monday, Wednesday", weekly.weeklyDayLabel)
        assertEquals(0b101, weekly.builtSchedule.weekdays)
        val picked = weekly.copy(weekday = 4, weeklyDayEdited = true)
        assertEquals("Friday", picked.weeklyDayLabel)
        assertEquals(0, picked.builtSchedule.weekdays)
        // Custom needs at least one day once every day is unticked.
        assertEquals(
            "Pick at least one day for a custom schedule.",
            ScheduleFields(scheduleKind = ScheduleKind.CUSTOM, customDays = 0).validation,
        )
        // Loading an empty custom schedule starts on Mon-Fri, like Apple.
        assertNull(ScheduleFields.load(AutomationSchedule(ScheduleKind.CUSTOM, weekdays = 0)).validation)
    }

    @Test
    fun intervalLabels() {
        assertEquals("90 seconds", JobScheduleCopy.intervalLabel(90))
        assertEquals("1 hour", JobScheduleCopy.intervalPresetLabel(60))
        assertEquals("2 hours", JobScheduleCopy.intervalPresetLabel(120))
        assertEquals("1 minute", JobScheduleCopy.intervalPresetLabel(1))
    }

    @Test
    fun automationDraftValidation() {
        val blank = AutomationEditorDraft.blank("w1")
        assertEquals("Give this job a name.", blank.validation)
        assertEquals(
            "Write what the agent should do.",
            blank.copy(name = "Nightly").validation,
        )
        assertEquals(
            "Choose a folder for this job.",
            blank.copy(name = "n", prompt = "p", workspaceID = "", backend = "codex").validation,
        )
        assertEquals(
            "Choose an agent for this job.",
            blank.copy(name = "n", prompt = "p").validation,
        )
        assertNull(blank.copy(name = "n", prompt = "p", backend = "codex").validation)
        val job = AutomationJob(
            id = "j", name = "n", backend = "codex", workspaceID = "w1", prompt = "p",
            schedule = AutomationSchedule(ScheduleKind.ONCE),
        )
        assertTrue(AutomationEditorDraft.fromJob(job).matches(job))
    }

    @Test
    fun budgetAndQueueValidation() {
        assertEquals(10_800L, BudgetFields.load(10_800).budgetSeconds)
        assertEquals(0L, BudgetFields.load(0).budgetSeconds)
        assertEquals(
            "Enter a positive time limit, or choose No limit.",
            BudgetFields("0").validation,
        )
        assertEquals(0L, QueueValidation.budgetSeconds(true, ""))
        assertEquals(10_800L, QueueValidation.budgetSeconds(false, "180"))
        assertNull(QueueValidation.budgetSeconds(false, "zero"))
        assertEquals(2L, QueueValidation.maxConcurrent("2"))
        assertNull(QueueValidation.maxConcurrent("many"))
    }

    @Test
    fun hostScheduleClock() {
        assertNull(HostScheduleClock.resolved(null))
        assertNull(HostScheduleClock.resolved("unknown"))
        assertNull(HostScheduleClock.resolved("  "))
        assertEquals("America/New_York", HostScheduleClock.resolved("America/New_York"))
        assertEquals("New York", HostScheduleClock.place("America/New_York"))
        assertEquals("UTC", HostScheduleClock.place("UTC"))
        // 2026-09-14 12:00 UTC is 08:00 in New York (EDT). The day
        // carries the year once this test runs in another year, so the
        // assertions read around it.
        val noon = 1_789_387_200_000L
        val wall = HostScheduleClock.wallClock(noon, "America/New_York")
        assertTrue(wall != null && wall.contains("14 Sep") && wall.endsWith("8:00"))
        val next = HostScheduleClock.nextRun(noon, "America/New_York")
        assertTrue(next.contains("14 Sep") && next.endsWith("8:00 in New York"))
        assertEquals("on the connected computer", HostScheduleClock.nextRun(noon, null))
        assertEquals(
            "Times are on Mac (New York).",
            HostScheduleClock.timesCaption("Mac", "America/New_York"),
        )
        assertEquals(
            "This time is on the connected computer, not this device.",
            HostScheduleClock.timeCaption("", null),
        )
    }

    @Test
    fun runHistoryLiveFirst() {
        val runs = listOf(
            RunRef("old-done", 1, false),
            RunRef("live", 2, true),
            RunRef("new-done", 9, false),
        )
        assertEquals(
            listOf("live", "new-done", "old-done"),
            RunHistory.ordered(runs).map { it.id },
        )
        assertEquals(2, RunHistory.remaining(total = 7, shown = 5))
        assertEquals(listOf("live", "new-done"), RunHistory.page(runs, 2).map { it.id })
    }
}
