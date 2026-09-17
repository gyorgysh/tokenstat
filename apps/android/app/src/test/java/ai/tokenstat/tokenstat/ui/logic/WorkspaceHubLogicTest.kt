// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceHubLogicTest {
    @Test
    fun hubSectionsFollowMacOrder() {
        assertEquals(
            listOf(
                "Sessions", "Chat", "Changes", "History", "Pull requests",
                "Tasks", "Notes", "Workflows", "Automations", "Files", "Browser",
            ),
            HubSection.entries.map { it.label },
        )
        assertEquals("Pulls", HubSection.PULLS.key)
        assertEquals("Tasks", HubSection.TASKS.key)
    }

    @Test
    fun hubCountsParseSummary() {
        val summary = buildJsonObject {
            put("id", "w1")
            put("sessions", 2)
            put("chats", 5)
            put("changed", 3)
            put("pulls", 1)
            put("tasks", 7)
            put("notes", 4)
            put("workflows", 6)
            put("workflowsRunning", 0)
            put("automations", 8)
        }
        val counts = HubCountsParser.parse(summary, gitChangedFallback = 9, cachedPulls = 9)
        assertEquals(HubCounts(2, 5, 3, 1, 7, 4, 8, 6), counts)
        assertEquals(2, counts.forSection(HubSection.SESSIONS))
        assertEquals(1, counts.forSection(HubSection.PULLS))
        assertNull(counts.forSection(HubSection.HISTORY))
        assertNull(counts.forSection(HubSection.FILES))
    }

    @Test
    fun hubCountsFallBackInsteadOfZero() {
        val summary = buildJsonObject {
            put("id", "w1")
            put("sessions", 0)
            put("tasks", 0)
            put("workflows", 6)
            put("workflowsRunning", 2)
            put("automations", 0)
        }
        val counts = HubCountsParser.parse(summary, gitChangedFallback = 3, cachedPulls = 4)
        assertEquals(3, counts.changes)
        assertEquals(4, counts.pulls)
        assertEquals(2, counts.workflows)
        assertEquals(0, counts.chats)
    }

    @Test
    fun hubCountsFindSummaryById() {
        val wanted = buildJsonObject {
            put("id", "w2")
            put("sessions", 1)
            put("tasks", 0)
            put("workflows", 0)
            put("workflowsRunning", 0)
            put("automations", 0)
        }
        val found = HubCountsParser.findSummary(
            listOf(buildJsonObject { put("id", "w1") }, wanted),
            "w2",
        )
        assertEquals(wanted, found)
        assertNull(HubCountsParser.findSummary(listOf(wanted), "missing"))
    }

    @Test
    fun chatHintNamesFolder() {
        assertEquals("Ask about this folder", ChatHint.hint("", false))
        assertEquals("Ask about this folder", ChatHint.hint("   ", false))
        assertEquals("Ask about 'tokenstat'", ChatHint.hint("tokenstat", false))
        assertEquals("Send after this turn", ChatHint.hint("tokenstat", true))
    }

    @Test
    fun launchCatalogParsesAndPartitions() {
        fun profile(id: String, installed: Boolean, hidden: Boolean = false) = buildJsonObject {
            put("id", id)
            put("name", id)
            put("command", "/bin/$id")
            putJsonArray("args") {}
            putJsonArray("bypassArgs") {}
            put("installed", installed)
            if (hidden) put("hidden", true)
        }
        val catalog = listOf(
            LaunchCatalog.parse(profile("a", true))!!,
            LaunchCatalog.parse(profile("b", true, hidden = true))!!,
            LaunchCatalog.parse(profile("c", false))!!,
        )
        assertEquals(listOf("a"), LaunchCatalog.visible(catalog, emptySet()).map { it.id })
        assertEquals(
            listOf("b", "c"),
            LaunchCatalog.extra(catalog, emptySet()).map { it.id },
        )
        assertEquals(
            listOf("a", "b", "c"),
            LaunchCatalog.extra(catalog, setOf("a")).map { it.id },
        )
        assertTrue(LaunchCatalog.visible(catalog, setOf("a")).isEmpty())
        val shell = LaunchCatalog.shellFallback()
        assertTrue(shell.installed)
        assertEquals("/bin/zsh", shell.command)
    }

    @Test
    fun launchArgsAddBypass() {
        val profile = LaunchCatalog.shellFallback().copy(args = listOf("-l"), bypassArgs = listOf("--no-ask"))
        assertEquals(listOf("-l"), profile.launchArgs(false))
        assertEquals(listOf("-l", "--no-ask"), profile.launchArgs(true))
    }

    @Test
    fun editorSaveDecidesConflict() {
        assertEquals(
            EditorSave.Outcome.CONFLICT,
            EditorSave.decide(host = "b", draft = "a", savedText = "saved"),
        )
        assertEquals(
            EditorSave.Outcome.ALREADY_SAVED,
            EditorSave.decide(host = "a", draft = "a", savedText = "saved"),
        )
        assertEquals(
            EditorSave.Outcome.SAVE,
            EditorSave.decide(host = "saved", draft = "a", savedText = "saved"),
        )
    }

    @Test
    fun editorConflictSummarizes() {
        assertEquals(1, EditorConflict.lineCount(""))
        assertEquals(3, EditorConflict.lineCount("a\nb\nc"))
        assertEquals(2, EditorConflict.firstDifferenceLine("a\nx", "a\ny"))
        assertEquals(3, EditorConflict.firstDifferenceLine("a\nb", "a\nb\nc"))
        assertNull(EditorConflict.firstDifferenceLine("a", "a"))
        assertEquals(
            "Yours has 2 lines, the host has 2. Saving is off until you choose. First difference: line 2.",
            EditorConflict.summary("a\nx", "a\ny"),
        )
    }

    @Test
    fun editorFindCountsAndNavigates() {
        val matches = EditorFind.matches("one two one", "one")
        assertEquals(2, matches.size)
        assertTrue(EditorFind.matches("abc", "").isEmpty())
        assertEquals("2 of 2", EditorFind.countLabel(1, 2))
        assertNull(EditorFind.countLabel(0, 0))
        assertEquals(0, EditorFind.nextIndex(1, 2))
        assertEquals(1, EditorFind.prevIndex(0, 2))
        assertEquals(0, EditorFind.nextIndex(0, 0))
    }

    @Test
    fun editorFindReplaces() {
        assertEquals(
            EditorFind.Replacement("a B c", 1),
            EditorFind.replaceFirst("a b c", "b", "B"),
        )
        assertEquals(
            EditorFind.Replacement("a B B", 2),
            EditorFind.replaceAll("a b b", "b", "B"),
        )
        assertEquals(
            EditorFind.Replacement("abc", 0),
            EditorFind.replaceAll("abc", "z", "B"),
        )
    }

    @Test
    fun pullReviewVerbs() {
        assertEquals(listOf("approve", "requestChanges", "comment"), PullReview.VERDICTS)
        assertEquals("Request changes", PullReview.verdictLabel("requestChanges"))
        assertEquals("Explain what needs to change…", PullReview.reviewPlaceholder("requestChanges"))
        assertEquals("Add a review note…", PullReview.reviewPlaceholder("comment"))
        assertEquals(listOf("merge", "squash", "rebase"), PullReview.MERGE_METHODS)
        assertEquals("Squash", PullReview.mergeTitle("squash"))
        assertFalse(PullReview.VERDICTS.isEmpty())
    }
}
