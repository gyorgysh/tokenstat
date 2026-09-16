// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTranscriptTest {
    private fun textEvent(delta: String, backend: String? = null, seq: Long? = null): JsonObject =
        buildJsonObject {
            put("kind", "agent")
            if (backend != null) put("backend", backend)
            if (seq != null) put("seq", seq)
            putJsonObject("event") {
                put("kind", "text")
                put("delta", delta)
            }
        }

    private fun toolStart(callId: String, verb: String, target: String): JsonObject =
        buildJsonObject {
            put("kind", "agent")
            put("atMs", 1000L)
            putJsonObject("event") {
                put("kind", "toolStart")
                put("callId", callId)
                put("verb", verb)
                put("target", target)
            }
        }

    private fun toolEnd(callId: String, verb: String, detail: String, ok: Boolean = true): JsonObject =
        buildJsonObject {
            put("kind", "agent")
            put("atMs", 2500L)
            putJsonObject("event") {
                put("kind", "toolEnd")
                put("callId", callId)
                put("verb", verb)
                put("ok", ok)
                put("detail", detail)
            }
        }

    @Test
    fun textDeltasCoalesceIntoOneAssistantItem() {
        val items = coalesceTranscript(
            listOf(textEvent("Hello "), textEvent("there")),
            defaultBackend = "codex",
        )
        assertEquals(1, items.size)
        val only = items[0] as ChatDisplayItem.Assistant
        assertEquals("Hello there", only.text)
        assertEquals("codex", only.backend)
    }

    @Test
    fun toolStartEndPairBecomesOneFinishedTool() {
        val items = coalesceTranscript(
            listOf(
                toolStart("c1", "Grep", "AGENTS.md"),
                toolEnd("c1", "Grep", "match one\nmatch two"),
            ),
        )
        assertEquals(1, items.size)
        val tool = (items[0] as ChatDisplayItem.Tool).state
        assertEquals("Grep", tool.verb)
        assertEquals("AGENTS.md", tool.target)
        assertFalse(tool.running)
        assertFalse(tool.failed)
        assertEquals(listOf("| match one", "| match two"), tool.snippet)
        assertEquals("1.5s", tool.duration)
    }

    @Test
    fun editVerbStartBecomesEditCardAndEndAppliesPatch() {
        val items = coalesceTranscript(
            listOf(
                toolStart("e1", "Edit", "src/a.ts"),
                toolEnd("e1", "Edit", "-old\n+new"),
            ),
        )
        assertEquals(1, items.size)
        val edit = (items[0] as ChatDisplayItem.Edit).state
        assertEquals("src/a.ts", edit.path)
        assertEquals("a.ts", edit.fileName)
        assertEquals("src", edit.location)
        assertEquals(1, edit.added)
        assertEquals(1, edit.removed)
        assertFalse(edit.running)
    }

    @Test
    fun orphanToolEndBecomesFallbackTool() {
        val items = coalesceTranscript(listOf(toolEnd("zz", "Bash", "out")))
        assertEquals(1, items.size)
        val tool = (items[0] as ChatDisplayItem.Tool).state
        assertEquals("zz", tool.callId)
        assertFalse(tool.running)
        assertEquals(listOf("| out"), tool.snippet)
    }

    @Test
    fun userTurnBoundsOpenTools() {
        val items = coalesceTranscript(
            listOf(
                toolStart("c1", "Bash", "sleep 9"),
                buildJsonObject {
                    put("kind", "user")
                    put("text", "stop")
                },
            ),
        )
        assertEquals(2, items.size)
        val tool = (items[0] as ChatDisplayItem.Tool).state
        assertFalse(tool.running)
        assertEquals("Interrupted", tool.detail)
        assertTrue(items[1] is ChatDisplayItem.User)
    }

    @Test
    fun backendChangeInsertsTurnSeparator() {
        val items = coalesceTranscript(
            listOf(
                textEvent("one", backend = "codex"),
                textEvent("two", backend = "Muse"),
            ),
        )
        assertEquals(3, items.size)
        assertTrue(items[0] is ChatDisplayItem.Assistant)
        val sep = items[1] as ChatDisplayItem.TurnSeparator
        assertEquals("Muse", sep.backend)
        assertTrue(items[2] is ChatDisplayItem.Assistant)
    }

    @Test
    fun usageIgnoresObjectInput() {
        val items = coalesceTranscript(
            listOf(
                buildJsonObject {
                    put("kind", "agent")
                    putJsonObject("event") {
                        put("kind", "usage")
                        putJsonObject("input") { put("x", 1) }
                        put("output", 42L)
                        put("cost_usd", 0.5)
                    }
                },
            ),
        )
        assertEquals(1, items.size)
        val usage = items[0] as ChatDisplayItem.Usage
        assertEquals(0, usage.input)
        assertEquals(42, usage.output)
        assertEquals(0.5, usage.costUsd!!, 0.0)
    }

    @Test
    fun failedToolEndMarksFailed() {
        val items = coalesceTranscript(
            listOf(
                toolStart("c1", "Bash", "exit 3"),
                toolEnd("c1", "Bash", "boom", ok = false),
            ),
        )
        val tool = (items[0] as ChatDisplayItem.Tool).state
        assertTrue(tool.failed)
    }

    @Test
    fun doneClosesRunningTools() {
        val items = coalesceTranscript(
            listOf(
                toolStart("c1", "Bash", "sleep 9"),
                buildJsonObject {
                    put("kind", "agent")
                    putJsonObject("event") {
                        put("kind", "done")
                        put("status", "ok")
                    }
                },
            ),
        )
        val tool = (items[0] as ChatDisplayItem.Tool).state
        assertFalse(tool.running)
        assertFalse(tool.failed)
    }

    @Test
    fun doneErrorFailsRunningTools() {
        val items = coalesceTranscript(
            listOf(
                toolStart("c1", "Bash", "sleep 9"),
                buildJsonObject {
                    put("kind", "agent")
                    putJsonObject("event") {
                        put("kind", "done")
                        put("status", "error")
                    }
                },
            ),
        )
        val tool = (items[0] as ChatDisplayItem.Tool).state
        assertTrue(tool.failed)
    }

    @Test
    fun snippetCapsLinesAndColumns() {
        val longLine = "x".repeat(700)
        val detail = (listOf(longLine) + (1..70).map { "line $it" }).joinToString("\n")
        val snippet = ChatToolState.makeSnippet("Bash", detail)
        assertEquals(61, snippet.size)
        assertTrue(snippet[0].startsWith("| xxx"))
        assertTrue(snippet[0].endsWith("…"))
        assertEquals(603, snippet[0].length)
        assertTrue(snippet.last().startsWith("| … (11 more)"))
    }

    @Test
    fun diffLinesStayUnprefixedInSnippet() {
        val snippet = ChatToolState.makeSnippet("Diff", "+new\n context\n-old")
        assertEquals(listOf("+new", "|  context", "-old"), snippet)
    }

    @Test
    fun durations() {
        assertEquals("250ms", ChatClock.duration(1000, 1250))
        assertEquals("1.5s", ChatClock.duration(1000, 2500))
        assertEquals("42s", ChatClock.duration(0, 42000))
        assertEquals(null, ChatClock.duration(0, null))
    }

    @Test
    fun ordinals() {
        assertEquals("1st", ChatClock.ordinal(1))
        assertEquals("2nd", ChatClock.ordinal(2))
        assertEquals("3rd", ChatClock.ordinal(3))
        assertEquals("11th", ChatClock.ordinal(11))
        assertEquals("22nd", ChatClock.ordinal(22))
    }
}
