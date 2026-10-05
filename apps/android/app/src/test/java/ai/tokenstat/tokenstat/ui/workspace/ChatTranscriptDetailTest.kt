// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The same cases as scripts/tests/ChatTranscriptFoldTests.swift, so the two
/// clients fold a conversation the same way.
class ChatTranscriptDetailTest {
    private fun user(id: String) = ChatDisplayItem.User(id, "q")
    private fun say(id: String) = ChatDisplayItem.Assistant(id, "a", null)
    private fun think(id: String, text: String = "## Plan\nread it") = ChatDisplayItem.Thinking(id, text)
    private fun usage(id: String, cost: Double) = ChatDisplayItem.Usage(id, 1, 1, cost)
    private fun failed(id: String) = ChatDisplayItem.Failed(id, "broke")
    private fun approval(id: String) = ChatDisplayItem.Approval(id, buildJsonObject { })
    private fun handoff(id: String) = ChatDisplayItem.Handoff(id, "codex", "b")
    private fun attachment(id: String) = ChatDisplayItem.Attachment(id, id, "f", null, null)

    private fun tool(
        id: String,
        verb: String,
        running: Boolean = false,
        failed: Boolean = false,
        start: Long = 0,
        end: Long? = null,
    ) = ChatDisplayItem.Tool(id, ChatToolState(id, verb, "t-$id", running, failed, null, start, end, emptyList()))

    private fun edit(id: String, path: String, added: Long = 0, removed: Long = 0, failed: Boolean = false, running: Boolean = false) =
        ChatDisplayItem.Edit(id, ChatEditState(path, added, removed, "", 1, running, failed, 0, null))

    private fun ids(rows: List<ChatDisplayItem>) = rows.map { it.id }

    private fun group(rows: List<ChatDisplayItem>, id: String): ChatStepGroup? =
        (rows.firstOrNull { it.id == id } as? ChatDisplayItem.Group)?.group

    private fun fold(
        rows: List<ChatDisplayItem>,
        detail: ChatDetail,
        running: Boolean = false,
        isOpen: (String) -> Boolean = { false },
    ) = foldTranscript(rows, detail, running, isOpen)

    @Test
    fun largeEditsRetainTheirTotalsAcrossEveryDetailLevel() {
        val count = 4_294_967_295L
        val rows = listOf(user("u1"), edit("e1", "a.kt", count, count), edit("e2", "a.kt", count, count), say("a1"))
        for (detail in ChatDetail.entries) {
            val output = fold(rows, detail)
            val changes = output.last() as ChatDisplayItem.Changes
            assertEquals(count * 2, changes.added)
            assertEquals(count * 2, changes.removed)
            assertEquals(count * 2, changes.files.single().added)
            if (detail == ChatDetail.Minimal) {
                assertEquals(count * 2, group(output, "g:e1")!!.added)
            }
        }
    }

    @Test
    fun detailedIsTheIdentity() {
        val rows = listOf(user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Read"), say("a1"), usage("x1", 0.1))
        assertEquals(rows, fold(rows, ChatDetail.Detailed))
    }

    @Test
    fun compactFoldsWorkBetweenQuestionAndAnswer() {
        val rows = listOf(
            user("u1"), think("k1"), say("a0"), tool("t1", "Bash"), edit("e1", "a.kt"), say("a1"), usage("x1", 0.25),
            user("u2"), tool("t2", "Read"), say("a2"),
        )
        val out = fold(rows, ChatDetail.Minimal)
        assertEquals(listOf("u1", "g:k1", "a0", "g:t1", "a1", "changes:e1", "u2", "g:t2", "a2"), ids(out))
        assertEquals(ChatStepGroup.Style.Thought, group(out, "g:k1")!!.style)
        val first = group(out, "g:t1")!!
        assertEquals(ChatStepGroup.Style.Work, first.style)
        assertEquals(listOf("t1", "e1"), first.memberIds)
        assertEquals(2, first.steps)
        assertEquals(0.25, first.cost!!, 0.0)
        assertNull(group(out, "g:t2")!!.cost)
    }

    @Test
    fun noLevelFoldsWhatAPersonMustSee() {
        val rows = listOf(
            user("u1"), tool("t1", "Bash"), approval("p1"), tool("t2", "Bash"),
            tool("t3", "Bash", failed = true), edit("e1", "a", failed = true), handoff("h1"),
            attachment("f1"), failed("x1"),
        )
        for (detail in ChatDetail.entries) {
            val out = fold(rows, detail)
            for (must in listOf("u1", "p1", "t3", "e1", "h1", "f1", "x1")) {
                assertTrue("$detail shows $must", out.any { it.id == must })
                assertNull("$detail never folds $must", stepGroupOwner(must, out))
            }
        }
        assertEquals(
            listOf("u1", "g:t1", "p1", "g:t2", "t3", "e1", "h1", "f1", "x1"),
            ids(fold(rows, ChatDetail.Minimal)),
        )
    }

    @Test
    fun compactKeepsUsageWhenThereIsNoWork() {
        assertEquals(listOf("u1", "a1", "x1"), ids(fold(listOf(user("u1"), say("a1"), usage("x1", 0.5)), ChatDetail.Minimal)))
        // Nothing spent, because a plan covers it, keeps the token counts.
        assertEquals(
            listOf("u1", "g:t1", "a1", "x1"),
            ids(fold(listOf(user("u1"), tool("t1", "Read"), say("a1"), usage("x1", 0.0)), ChatDetail.Minimal)),
        )
    }

    @Test
    fun compactKeepsEveryReplyVisible() {
        val rows = listOf(user("u1"), say("a0"), tool("t1", "Read"), say("a1"),
            tool("t2", "Bash", running = true), say("a2"))
        for (running in listOf(false, true)) {
            val out = fold(rows, ChatDetail.Minimal, running = running)
            assertEquals(listOf("u1", "a0", "g:t1", "a1", "g:t2", "a2"), ids(out))
            for (id in listOf("a0", "a1", "a2")) assertNull(stepGroupOwner(id, out))
        }
    }

    @Test
    fun compactLiveTurn() {
        val rows = listOf(user("u1"), think("k1"), tool("t1", "Read", running = true))
        val live = group(fold(rows, ChatDetail.Minimal, running = true), "g:k1")!!
        assertTrue(live.running)
        assertEquals("Read", live.liveVerb)
        assertEquals("t-t1", live.liveTarget)

        val streaming = fold(rows + say("a1"), ChatDetail.Minimal, running = true)
        assertEquals(listOf("u1", "g:k1", "a1"), ids(streaming))
        assertTrue(group(streaming, "g:k1")!!.running)

        val settled = fold(listOf(user("u1"), think("k1"), tool("t1", "Read"), say("a1")), ChatDetail.Minimal, running = true)
        assertFalse(group(settled, "g:k1")!!.running)
    }

    @Test
    fun standardFoldsReadsAndThinking() {
        val rows = listOf(
            user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Grep"), tool("t3", "WebFetch"),
            tool("t4", "Bash"), edit("e1", "a"), say("a1"), usage("x1", 0.1),
        )
        val out = fold(rows, ChatDetail.Standard)
        assertEquals(listOf("u1", "g:k1", "g:t1", "t4", "e1", "a1", "x1", "changes:e1"), ids(out))
        assertEquals(ChatStepGroup.Style.Thought, group(out, "g:k1")!!.style)
        val explored = group(out, "g:t1")!!
        assertEquals(ChatStepGroup.Style.Explored, explored.style)
        assertEquals(1, explored.reads)
        assertEquals(1, explored.searches)
        assertEquals(1, explored.pages)
    }

    @Test
    fun standardKeepsALoneReadAndBreaksRuns() {
        val rows = listOf(
            user("u1"), tool("t1", "Read"), tool("t2", "Bash"), tool("t3", "Read"), tool("t4", "Glob"),
            tool("t5", "Read", failed = true), tool("t6", "Read"),
        )
        assertEquals(listOf("u1", "t1", "t2", "g:t3", "t5", "t6"), ids(fold(rows, ChatDetail.Standard)))
    }

    @Test
    fun standardLeavesStreamingThoughtOpen() {
        val rows = listOf(user("u1"), think("k1"))
        assertEquals(listOf("u1", "k1"), ids(fold(rows, ChatDetail.Standard, running = true)))
        assertEquals(listOf("u1", "g:k1"), ids(fold(rows, ChatDetail.Standard, running = false)))
    }

    @Test
    fun openGroupsListTheirStepsAsRows() {
        val rows = listOf(user("u1"), think("k1"), tool("t1", "Bash"), say("a1"))
        val out = fold(rows, ChatDetail.Minimal) { it == "g:k1" }
        assertEquals(listOf("u1", "g:k1", "k1", "t1", "a1"), ids(out))
        assertTrue(group(out, "g:k1")!!.open)
        val step = out[3] as ChatDisplayItem.GroupStep
        assertEquals("g:k1", step.groupId)
        assertTrue(step.item is ChatDisplayItem.Tool)
        assertNull(stepGroupOwner("t1", out))
    }

    @Test
    fun groupIdsHoldWhileATurnGrows() {
        val rows = mutableListOf<ChatDisplayItem>(user("u1"), think("k1"), tool("t1", "Bash", running = true))
        val before = ids(fold(rows, ChatDetail.Minimal, running = true))
        rows.add(tool("t2", "Bash", running = true))
        val after = ids(fold(rows, ChatDetail.Minimal, running = true))
        assertEquals(before, after)
        assertEquals(listOf("u1", "g:k1"), after)
        val paged = listOf(user("u0"), say("a0")) + rows
        assertEquals(listOf("u1", "g:k1"), ids(fold(paged, ChatDetail.Minimal, running = true)).takeLast(2))
    }

    @Test
    fun ownerFindsClosedMembersOnly() {
        val rows = listOf(user("u1"), tool("t1", "Read"), tool("t2", "Read"), think("k1"), say("a1"))
        val standard = fold(rows, ChatDetail.Standard)
        assertEquals("g:t1", stepGroupOwner("t2", standard))
        assertEquals("g:k1", stepGroupOwner("k1", standard))
        assertNull(stepGroupOwner("a1", standard))
        assertNull(stepGroupOwner("missing", standard))
        assertEquals("g:t1", stepGroupOwner("t2", fold(rows, ChatDetail.Minimal)))
    }

    @Test
    fun countsMatchTheirMembers() {
        val rows = listOf(
            user("u1"),
            tool("t1", "Bash", start = 1_000, end = 4_000),
            edit("e1", "a.kt", added = 3, removed = 1),
            edit("e2", "a.kt", added = 2),
            edit("e3", "b.kt", added = 1, removed = 4),
            tool("t2", "Bash", start = 5_000, end = 9_000),
            say("a1"),
        )
        val work = group(fold(rows, ChatDetail.Minimal), "g:t1")!!
        assertEquals(5, work.steps)
        assertEquals(2, work.files)
        assertEquals(6L, work.added)
        assertEquals(5L, work.removed)
        assertEquals(1_000L, work.startedAtMs)
        assertEquals(9_000L, work.endedAtMs)
    }

    @Test
    fun previewDropsMarkdownMarks() {
        assertEquals("Plan** it", thoughtPreview("\n\n## **Plan** it\nmore"))
        assertEquals("check the tests", thoughtPreview("  \n- check the tests"))
        assertNull(thoughtPreview("\n  \n"))
    }

    @Test
    fun compactMakesEveryStepOneLine() {
        val rows = listOf(
            user("u1"), think("k1"), tool("t1", "Read"), tool("t2", "Grep"), tool("t3", "Bash"),
            edit("e1", "src/a.kt", added = 6, removed = 2), tool("t4", "Read"), say("a1"), tool("t5", "Bash", failed = true),
        )
        val out = fold(rows, ChatDetail.Compact)
        assertEquals(listOf("u1", "g:k1", "g:t1", "g:t3", "g:e1", "g:t4", "a1", "t5", "changes:e1"), ids(out))
        for (id in listOf("g:k1", "g:t1", "g:t3", "g:e1", "g:t4")) assertTrue(id, group(out, id)!!.plain)
        val ran = group(out, "g:t3")!!
        assertEquals(ChatStepGroup.Style.Step, ran.style)
        assertEquals("Bash", ran.verb)
        val edited = group(out, "g:e1")!!
        assertEquals("Edit", edited.verb)
        assertEquals("src/a.kt", edited.subject)
        assertEquals(6L, edited.added)
        assertEquals(ChatStepGroup.Style.Explored, group(out, "g:t4")!!.style)
        assertNull(stepGroupOwner("t5", out))
        assertEquals("a.kt", shortStepSubject("Edit", "src/a.kt"))
        assertEquals("cargo test", shortStepSubject("Bash", "cargo test\nmore"))
    }

    @Test
    fun anOpenCompactLineShowsItsStepWithoutACard() {
        val lone = fold(listOf(user("u1"), edit("e1", "a.kt", added = 1), say("a1")), ChatDetail.Compact) { it == "g:e1" }
        assertEquals(PlainStep.Detail, lone.filterIsInstance<ChatDisplayItem.GroupStep>().single().plain)
        val run = fold(listOf(user("u1"), tool("t1", "Read"), tool("t2", "Grep"), say("a1")), ChatDetail.Compact) { it == "g:t1" }
        assertTrue(run.filterIsInstance<ChatDisplayItem.GroupStep>().all { it.plain == PlainStep.Line })
        val minimal = fold(listOf(user("u1"), tool("t1", "Read"), say("a1")), ChatDetail.Minimal) { true }
        assertTrue(minimal.filterIsInstance<ChatDisplayItem.GroupStep>().all { it.plain == null })
    }

    @Test
    fun aStoredChoiceKeepsWhatItDidAcrossTheRename() {
        assertEquals(ChatDetail.Compact, renamedDetail("minimal"))
        assertEquals(ChatDetail.Minimal, renamedDetail("compact"))
        assertEquals(ChatDetail.Standard, renamedDetail("standard"))
        assertNull(renamedDetail("unknown"))
    }

    @Test
    fun turnChangesSumPerFileAndWaitForTheTurn() {
        val rows = listOf(
            user("u1"), edit("e1", "/w/a.kt", added = 3, removed = 1), edit("e2", "/w/a.kt", added = 2),
            edit("e3", "/w/b.kt", added = 1, removed = 4), edit("ef", "/w/c.kt", failed = true), say("a1"),
            user("u2"), edit("e4", "/w/c.kt", added = 1), edit("er", "/w/d.kt", running = true), say("a2"),
        )
        val live = fold(rows, ChatDetail.Minimal, running = true)
        assertEquals(listOf("changes:e1"), ids(live).filter { it.startsWith("changes:") })
        val first = live.first { it.id == "changes:e1" } as ChatDisplayItem.Changes
        assertEquals(listOf("/w/a.kt", "/w/b.kt"), first.files.map { it.path })
        assertEquals(5L, first.files[0].added)
        assertEquals(6L, first.added)
        assertEquals(5L, first.removed)
        val finished = fold(rows, ChatDetail.Minimal, running = false)
        assertEquals(listOf("/w/c.kt"), (finished.last() as ChatDisplayItem.Changes).files.map { it.path })
    }
}
