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
