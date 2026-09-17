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
import ai.tokenstat.tokenstat.ui.automations.AutomationQueue
import ai.tokenstat.tokenstat.ui.automations.AutomationRun
import ai.tokenstat.tokenstat.ui.automations.AutomationSchedule
import ai.tokenstat.tokenstat.ui.automations.BudgetFields
import ai.tokenstat.tokenstat.ui.automations.HostScheduleClock
import ai.tokenstat.tokenstat.ui.automations.JobCopy
import ai.tokenstat.tokenstat.ui.automations.JobScheduleCopy
import ai.tokenstat.tokenstat.ui.automations.QueueCopy
import ai.tokenstat.tokenstat.ui.automations.QueueDraft
import ai.tokenstat.tokenstat.ui.automations.QueueValidation
import ai.tokenstat.tokenstat.ui.automations.ScheduleFields
import ai.tokenstat.tokenstat.ui.automations.ScheduleKind
import ai.tokenstat.tokenstat.ui.automations.automationListSummary
import ai.tokenstat.tokenstat.ui.automations.jobMatchesQuery
import ai.tokenstat.tokenstat.ui.automations.lastAutomationRun
import ai.tokenstat.tokenstat.ui.tasks.allRunsLabel
import ai.tokenstat.tokenstat.ui.workflows.AgentBackend
import ai.tokenstat.tokenstat.ui.workflows.WorkflowEdge
import ai.tokenstat.tokenstat.ui.workflows.WorkflowEdgeWhen
import ai.tokenstat.tokenstat.ui.workflows.WorkflowEditorDraft
import ai.tokenstat.tokenstat.ui.workflows.WorkflowGraph
import ai.tokenstat.tokenstat.ui.workflows.WorkflowGraphRules
import ai.tokenstat.tokenstat.ui.workflows.WorkflowModelPick
import ai.tokenstat.tokenstat.ui.workflows.WorkflowNode
import ai.tokenstat.tokenstat.ui.workflows.WorkflowNodeKind
import ai.tokenstat.tokenstat.ui.workflows.WorkflowRecipes
import ai.tokenstat.tokenstat.ui.workflows.WorkflowRunRecord
import ai.tokenstat.tokenstat.ui.workflows.graphMatchesQuery
import ai.tokenstat.tokenstat.ui.workflows.lastWorkflowRun
import ai.tokenstat.tokenstat.ui.workflows.workflowContentMatches
import ai.tokenstat.tokenstat.ui.workflows.workflowListSummary
import ai.tokenstat.tokenstat.ui.editor.EditorFind
import ai.tokenstat.tokenstat.ui.editor.EditorGutterMap
import ai.tokenstat.tokenstat.ui.editor.SyntaxSpan
import ai.tokenstat.tokenstat.ui.editor.changedLinesFromDiff
import ai.tokenstat.tokenstat.ui.editor.firstDifference
import ai.tokenstat.tokenstat.ui.theme.SyntaxKind
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
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
    fun workflowConnectionRoles() {
        assertEquals("Then", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.AGENT, WorkflowEdgeWhen.OK))
        assertEquals("On error", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.AGENT, WorkflowEdgeWhen.ERROR))
        assertEquals("Always", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.AGENT, WorkflowEdgeWhen.ALWAYS))
        assertEquals("Then", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.CONDITION, WorkflowEdgeWhen.OK))
        assertEquals("Else", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.CONDITION, WorkflowEdgeWhen.ERROR))
        assertEquals("Body", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.LOOP, WorkflowEdgeWhen.OK))
        assertEquals("After last pass", WorkflowGraphRules.outgoingRole(WorkflowNodeKind.LOOP, WorkflowEdgeWhen.ALWAYS))
        assertEquals(
            WorkflowEdgeWhen.ERROR,
            WorkflowGraphRules.suggestedWhen(WorkflowNodeKind.AGENT, listOf(WorkflowEdge("a", "b", WorkflowEdgeWhen.OK))),
        )
        assertEquals(
            WorkflowEdgeWhen.ALWAYS,
            WorkflowGraphRules.suggestedWhen(WorkflowNodeKind.LOOP, listOf(WorkflowEdge("a", "b", WorkflowEdgeWhen.OK))),
        )
    }

    @Test
    fun workflowGraphIssues() {
        val start = WorkflowNode(id = "in", kind = WorkflowNodeKind.INPUT, title = "Start")
        val agent = WorkflowNode(id = "n2", kind = WorkflowNodeKind.AGENT, title = "Build", backend = "codex")
        assertNull(WorkflowGraphRules.stepsIssue(listOf(start, agent), listOf(WorkflowEdge("in", "n2"))))
        assertEquals(
            "A step cannot connect to itself.",
            WorkflowGraphRules.connectionIssue("a", "a", listOf(start), emptyList()),
        )
        assertEquals(
            "Two steps share the id n2.",
            WorkflowGraphRules.stepsIssue(listOf(start, agent, agent.copy()), listOf(WorkflowEdge("in", "n2"))),
        )
        // A cycle without a Loop step is illegal; through a loop it is fine.
        val a = WorkflowNode(id = "a", kind = WorkflowNodeKind.AGENT, backend = "codex")
        val b = WorkflowNode(id = "b", kind = WorkflowNodeKind.AGENT, backend = "codex")
        assertEquals(
            "This graph loops without a Loop step.",
            WorkflowGraphRules.stepsIssue(listOf(a, b), listOf(WorkflowEdge("a", "b"), WorkflowEdge("b", "a"))),
        )
        val loop = WorkflowNode(id = "loop", kind = WorkflowNodeKind.LOOP, times = 3)
        assertNull(WorkflowGraphRules.stepsIssue(listOf(a, loop), listOf(WorkflowEdge("a", "loop"), WorkflowEdge("loop", "a"))))
        assertEquals(
            "Loop Loop needs a body connection.",
            WorkflowGraphRules.stepsIssue(
                listOf(loop, a),
                listOf(WorkflowEdge("loop", "a", WorkflowEdgeWhen.ERROR)),
            ),
        )
        assertEquals(
            "An agent step needs an agent.",
            WorkflowGraphRules.nodeIssue(WorkflowNode(id = "x", kind = WorkflowNodeKind.AGENT)),
        )
        assertEquals(
            "An HTTP URL must start with http:// or https://.",
            WorkflowGraphRules.nodeIssue(WorkflowNode(id = "x", kind = WorkflowNodeKind.HTTP, url = "ftp://x")),
        )
        assertEquals(
            "A command step needs a command.",
            WorkflowGraphRules.nodeIssue(WorkflowNode(id = "x", kind = WorkflowNodeKind.COMMAND)),
        )
        assertEquals("MCP steps are not available yet.", WorkflowGraphRules.additionIssue(WorkflowNodeKind.MCP, 0))
        assertTrue(WorkflowGraphRules.isPathSafeID("n12-ok_x"))
        assertTrue(!WorkflowGraphRules.isPathSafeID("has space"))
        assertEquals("n3", WorkflowGraphRules.nextNodeID(listOf(start, agent)))
        val made = WorkflowGraphRules.makeNode(WorkflowNodeKind.AGENT, "n9", backend = "codex")
        assertEquals("{{input}}", made.prompt)
        assertEquals("exit", made.wait)
    }

    @Test
    fun workflowDraftValidation() {
        val blank = WorkflowEditorDraft.blank("w1")
        assertEquals("Give this workflow a name.", blank.copy(name = "").validation)
        assertEquals("Choose a folder for this workflow.", blank.copy(name = "W", workspaceID = "").validation)
        assertNull(blank.copy(name = "W").validation)
        val graph = WorkflowGraph.blank("W", "w1").copy(
            revision = 7,
            schedule = ai.tokenstat.tokenstat.ui.automations.AutomationSchedule(
                ai.tokenstat.tokenstat.ui.automations.ScheduleKind.ONCE,
            ),
        )
        val draft = WorkflowEditorDraft.fromGraph(graph)
        assertTrue(draft.matches(graph))
        assertTrue(!draft.copy(name = "Other").matches(graph))
        val made = draft.copy(name = "W").makeGraph("wf-1")
        assertEquals("wf-1", made.id)
        assertEquals(WorkflowEditorDraft.BLANK_STARTER_ID, WorkflowEditorDraft.blank("w1").starterID)
    }

    @Test
    fun workflowRecipesAndPicks() {
        val backends = listOf(
            AgentBackend("codex", "Codex", listOf("gpt-5-mini", "gpt-5"), listOf("low", "high")),
            AgentBackend("claude", "Claude", listOf("haiku", "opus"), listOf("low", "high")),
        )
        assertEquals("gpt-5-mini", WorkflowModelPick.cheapestModel("codex", backends[0].models))
        assertEquals("low", WorkflowModelPick.lowestEffort(backends[0].efforts))
        assertEquals("high", WorkflowModelPick.highestEffort(backends[0].efforts))
        val recipes = WorkflowRecipes.recipes(backends)
        assertEquals(2, recipes.size)
        assertEquals("Plan, build, review", recipes[0].name)
        assertEquals("Plan then build", recipes[1].name)
        assertTrue(recipes[0].nodes.any { it.kind == WorkflowNodeKind.CONDITION } .not())
        assertTrue(WorkflowRecipes.designAgents(backends).isNotEmpty())
        assertTrue(recipes[0].label.contains("Start") && recipes[0].label.contains("Done"))
    }

    @Test
    fun workflowLayoutAndContentMatch() {
        val graph = WorkflowGraph(
            name = "W",
            nodes = listOf(
                WorkflowNode(id = "in", kind = WorkflowNodeKind.INPUT),
                WorkflowNode(id = "n2", kind = WorkflowNodeKind.AGENT),
            ),
            edges = listOf(WorkflowEdge("in", "n2")),
        )
        val laid = graph.layoutIfNeeded()
        assertTrue(laid.nodes[1].y > laid.nodes[0].y)
        assertTrue(workflowContentMatches(graph, graph.copy(revision = 9, lastRunID = "r")))
        assertTrue(!workflowContentMatches(graph, graph.copy(name = "Other")))
        assertEquals("Needs attention", WorkflowRunRecord.label("waiting"))
        assertEquals("Working", WorkflowRunRecord.label("running"))
    }

    @Test
    fun editorFindSession() {
        val find = EditorFind()
        find.query = "hello"
        find.refresh("say hello, HELLO again")
        assertEquals(2, find.matchCount)
        assertEquals("1 of 2", find.countLabel)
        assertTrue(find.canNavigate)
        assertTrue(find.canReplace)
        find.goNext()
        assertEquals("2 of 2", find.countLabel)
        find.goNext()
        assertEquals("1 of 2", find.countLabel)
        find.goPrevious()
        assertEquals("2 of 2", find.countLabel)
        find.replaceText = "hi"
        val replaced = find.replaceCurrent("say hello, HELLO again")
        assertEquals("say hello, hi again", replaced)
        val cleared = EditorFind()
        cleared.query = "hello"
        cleared.replaceText = "hi"
        cleared.refresh("hello hello")
        assertEquals("hi hi", cleared.replaceAll("hello hello"))
        val empty = EditorFind()
        empty.refresh("text")
        assertNull(empty.countLabel)
        empty.query = "missing"
        empty.refresh("text")
        assertEquals("No results", empty.countLabel)
        assertTrue(!empty.canNavigate && !empty.canReplace)
        val flood = EditorFind()
        flood.query = "a"
        flood.refresh("a".repeat(3000))
        assertEquals(2000, flood.matchCount)
        assertEquals("1 of 2000+", flood.countLabel)
    }

    @Test
    fun editorGutterMath() {
        val starts = EditorGutterMap.lineStarts("ab\nc\n")
        assertEquals(listOf(0, 3, 5), starts)
        assertEquals(1, EditorGutterMap.paragraph(0, starts))
        assertEquals(2, EditorGutterMap.paragraph(3, starts))
        assertEquals(3, EditorGutterMap.paragraph(5, starts))
        assertNull(firstDifference("same", "same"))
        assertEquals(2, firstDifference("a\nb\n", "a\nc\n"))
        assertEquals(3, firstDifference("a\nb", "a\nb\nc"))
    }

    @Test
    fun editorSyntaxAndDiff() {
        assertEquals(SyntaxKind.Keyword, SyntaxSpan.syntaxKindOf("keyword"))
        assertEquals(SyntaxKind.Unknown, SyntaxSpan.syntaxKindOf("frobnicator"))
        assertEquals(SyntaxKind.Unknown, SyntaxSpan.syntaxKindOf(null))
        val span = SyntaxSpan(8, 10, SyntaxKind.String)
        assertEquals(SyntaxSpan(8, 2, SyntaxKind.String), span.clamped(10))
        assertNull(SyntaxSpan(12, 3, SyntaxKind.String).clamped(10))
        val diff = buildJsonObject {
            put("hunks", JsonArray(listOf(buildJsonObject {
                put("lines", JsonArray(listOf(
                    buildJsonObject {
                        put("kind", "context")
                        put("oldLine", 1)
                        put("newLine", 1)
                    },
                    buildJsonObject {
                        put("kind", "added")
                        put("newLine", 3)
                    },
                    buildJsonObject {
                        put("kind", "removed")
                        put("oldLine", 4)
                    },
                )))
            })))
        }
        assertEquals(setOf(3), changedLinesFromDiff(diff))
        assertEquals(emptySet<Int>(), changedLinesFromDiff(null))
        assertEquals(emptySet<Int>(), changedLinesFromDiff(JsonObject(emptyMap())))
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

    @Test
    fun runHistoryPreviewGateAndLatest() {
        assertTrue(!RunHistory.showsAllRuns(5))
        assertTrue(RunHistory.showsAllRuns(6))
        assertEquals("live", RunHistory.latest(listOf(RunRef("done", 9, false), RunRef("live", 2, true)))?.id)
        assertNull(RunHistory.latest(emptyList()))
        assertEquals("All runs", allRunsLabel(1))
        assertEquals("All 6 runs", allRunsLabel(6))
    }

    @Test
    fun jobConfirmCopy() {
        assertEquals("Starts Nightly in Site on Mac.", JobCopy.run("Nightly", "Site", "Mac"))
        assertEquals("Stops the run of Nightly in Site on Mac.", JobCopy.stop("Nightly", "Site", "Mac"))
        assertEquals("Lets Nightly continue in Site on Mac.", JobCopy.continueGate("Nightly", "Site", "Mac"))
        assertEquals("No time limit", JobCopy.budget(0))
        assertEquals("1 minute", JobCopy.budget(60))
        assertEquals("2 minutes", JobCopy.budget(120))
        assertEquals("1 hour", JobCopy.budget(3600))
        assertEquals("3 hours", JobCopy.budget(10_800))
        assertEquals("Never run", JobCopy.lastRunWhen(null))
        assertEquals("Never run", JobCopy.lastRunWhen(0))
        assertEquals("2 min ago", JobCopy.lastRunWhen(1_700_000_000_000 - 90_000, 1_700_000_000_000))
    }

    @Test
    fun schedulerCardCopy() {
        assertEquals("No time limit · 2 at once", QueueCopy.summary(0, 2))
        assertEquals("3h per job · No cap", QueueCopy.summary(10_800, 0))
        assertEquals("15m per job · 1 at once", QueueCopy.summary(900, 1))
        assertEquals("10 min per job · 2 at once", QueueCopy.summary(600, 2))
        assertEquals("On Mac, not just Site", QueueCopy.scope("Mac", "Site"))
        assertEquals("Every folder on the connected computer", QueueCopy.scope("", ""))
        assertEquals("Every folder on Mac", QueueCopy.scope("Mac", ""))
        assertEquals("Every folder, not just Site", QueueCopy.scope("", "Site"))
        assertEquals("Every folder on Mac", QueueCopy.scope("Mac", "Site", compact = true))
        assertEquals("Every folder", QueueCopy.scope("", "", compact = true))
        assertEquals(
            "How queued jobs run on Mac, not just Site.",
            QueueCopy.editorScope("Mac", "Site"),
        )
        assertEquals(
            "How queued jobs run on the connected computer. This applies to every folder.",
            QueueCopy.editorScope("", ""),
        )
        assertEquals("The clock on Mac is New York.", QueueCopy.clockCaption("Mac", "America/New_York"))
        assertEquals(
            "The clock is on the connected computer, not this device.",
            QueueCopy.clockCaption("", "unknown"),
        )
    }

    @Test
    fun queueValidationMatchesApple() {
        assertEquals(32L, QueueValidation.maxConcurrent("32"))
        assertNull(QueueValidation.maxConcurrent("33"))
        assertEquals("At most 32 jobs can run at once.", QueueValidation.maxConcurrentError("33"))
        assertEquals("Jobs at once must be a whole number, or No cap.", QueueValidation.maxConcurrentError("many"))
        assertEquals(
            "Enter a positive time limit, or choose No limit.",
            QueueValidation.budgetError(false, "0"),
        )
        assertTrue(QueueValidation.isBudgetPreset(false, "180"))
        assertTrue(!QueueValidation.isBudgetPreset(false, "181"))
        assertTrue(!QueueValidation.isBudgetPreset(true, "180"))
        assertTrue(QueueValidation.isConcurrentPreset("0"))
        assertTrue(QueueValidation.isConcurrentPreset("8"))
        assertTrue(!QueueValidation.isConcurrentPreset("3"))
        assertTrue(QueueDraft("180", false, "2").matches(AutomationQueue(10_800, 2, null)))
        assertTrue(!QueueDraft("30", false, "2").matches(AutomationQueue(10_800, 2, null)))
    }

    @Test
    fun librarySummariesAndSearch() {
        assertEquals("2 enabled · 1 running", automationListSummary(2, 1))
        assertEquals("3 workflows · 0 running", workflowListSummary(3, 0))
        val job = AutomationJob(id = "j", name = "Nightly", prompt = "run the tests")
        assertTrue(jobMatchesQuery(job, ""))
        assertTrue(jobMatchesQuery(job, "night"))
        assertTrue(jobMatchesQuery(job, "TESTS"))
        assertTrue(!jobMatchesQuery(job, "nope"))
        val graph = WorkflowGraph(id = "g", name = "Deploy")
        assertTrue(graphMatchesQuery(graph, ""))
        assertTrue(graphMatchesQuery(graph, "dep"))
        assertTrue(!graphMatchesQuery(graph, "tests"))
    }

    @Test
    fun lastRunSelection() {
        val runs = listOf(
            AutomationRun(id = "r1", jobId = "a", startedAtMs = 100, status = "ok"),
            AutomationRun(id = "r2", jobId = "a", startedAtMs = 50, status = "running"),
            AutomationRun(id = "r3", jobId = "b", startedAtMs = 300, status = "ok"),
        )
        assertEquals("r2", lastAutomationRun(runs, AutomationJob(id = "a", lastRunID = "r1"))?.id)
        assertEquals("r3", lastAutomationRun(runs, AutomationJob(id = "missing", lastRunID = "r3"))?.id)
        assertNull(lastAutomationRun(runs, AutomationJob(id = "missing")))
        val workflows = listOf(
            WorkflowRunRecord(id = "w1", workflowID = "g", startedAtMs = 100),
            WorkflowRunRecord(id = "w2", workflowID = "g", startedAtMs = 200),
        )
        assertEquals("w2", lastWorkflowRun(workflows, WorkflowGraph(id = "g", lastRunID = "w2"))?.id)
        assertEquals("w1", lastWorkflowRun(workflows, WorkflowGraph(id = "g"))?.id)
        assertNull(lastWorkflowRun(workflows, WorkflowGraph(id = "missing")))
    }
}
