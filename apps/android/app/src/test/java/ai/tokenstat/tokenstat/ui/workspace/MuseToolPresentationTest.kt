// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class MuseToolPresentationTest {
    private fun refine(verb: String, detail: String?, target: String = "", backend: String? = "muse") =
        refineMuseToolPresentation(backend, verb, target, detail)

    @Test fun shellTargetsComeFromTheRecordedCommand() {
        val raw = """{"command":"rg --files src","description":"List project files","output":"src/main.rs"}"""
        assertEquals(MuseToolPresentation("Bash", "rg --files src"), refine("Bash", raw))
        assertEquals(MuseToolPresentation("Bash", "git status --short"),
            refine("Bash Input", "Check working tree\n$ git status --short\n M README.md"))
        assertEquals("pwd", refine("bash_input", "$ pwd\n/tmp/project").target)
        assertEquals("", refine("Bash", "Unstructured tool output").target)
        assertEquals("", refine("Bash", "{bad JSON\n$ not a recorded command").target)
    }

    @Test fun readsAndWritesUseOnlyTheInitialReportedFile() {
        assertEquals("/tmp/project/AGENTS.md", refine("Read", "Read text file `/tmp/project/AGENTS.md`.\nInstructions").target)
        assertEquals("/tmp/project/file with spaces.txt", refine("Write", "wrote 23 bytes to /tmp/project/file with spaces.txt").target)
        assertEquals("", refine("Read", "File contents\nRead text file `/tmp/not-the-target`.").target)
        assertEquals("", refine("Write", "Output\nwrote 23 bytes to /tmp/not-the-target").target)
    }

    @Test fun searchesRequireAnExplicitQueryAndFetchesNeverUseOutputLinks() {
        assertEquals("Muse cli docs", refine("WebSearch", """{"query":"Muse cli docs","results":[]}""").target)
        assertEquals("", refine("WebSearch", """{"results":[{"title":"Muse cli docs","url":"https://example.test/result"}]}""").target)
        assertEquals("", refine("WebSearch", """{"query":42,"results":[]}""").target)
        assertEquals("", refine("WebFetch", "See https://example.test/output-link").target)
        assertEquals("", refine("Grep", "Matches for a possible query in file.txt").target)
    }

    @Test fun skillHeadersWorkForLegacyAndCanonicalReadVerbs() {
        val detail = "<read-skill-result name=\"bundled:git\" status=\"ok\">\n# Git\n</read-skill-result>"
        for (verb in listOf("Read Skill", "read_skill", "Read")) {
            assertEquals(MuseToolPresentation("Read", "bundled:git"), refine(verb, detail))
        }
        assertEquals("", refine("Read Skill", "Output\n$detail").target)
        assertEquals("", refine("Read Skill", "<other-result name=\"bundled:git\">").target)
    }

    @Test fun todoRowsUseAnExplicitCountAndRevision() {
        assertEquals(MuseToolPresentation("TodoWrite", "4 todos (revision 2)"),
            refine("Write Todos", """{"ok":true,"revision":2,"items":4}"""))
        assertEquals(MuseToolPresentation("TodoWrite", "4 todos (revision 2)"),
            refine("write_todos", "4 todos (revision 2)"))
        assertEquals("1 todo", refine("TodoWrite", """{"ok":true,"items":1}""").target)
        assertEquals("", refine("TodoWrite", "Unstructured todo output").target)
        assertEquals("", refine("TodoWrite", """{"items":-1,"revision":2}""").target)
    }

    @Test fun existingTargetsAndUnrecognizedToolsArePreserved() {
        assertEquals(MuseToolPresentation("Bash", "explicit --target"),
            refine("Bash Input", """{"command":"another --command"}""", target = "explicit --target"))
        assertEquals(MuseToolPresentation("Custom Tool", ""),
            refine("Custom Tool", """{"command":"not a shell tool","query":"not a search tool"}"""))
        for (backend in listOf(null, "codex", "claude", "grok")) {
            assertEquals(MuseToolPresentation("Bash Input", ""),
                refine("Bash Input", """{"command":"must remain untouched"}""", backend = backend))
        }
    }

    @Test fun parsingIsBoundedByUtf8BytesAndInferredTargetsUseTheRowLimit() {
        assertEquals("", refine("Bash", """{"command":"pwd","output":"${"x".repeat(128 * 1024)}"}""").target)
        assertEquals("", refine("Bash", """{"command":"pwd","output":"${"é".repeat(70 * 1024)}"}""").target)
        val command = "x".repeat(700)
        assertEquals(ChatToolState.clip(command), refine("Bash", """{"command":"$command"}""").target)
    }

    private fun event(kind: String, verb: String? = null, target: String? = null,
                      detail: String? = null, backend: String? = null): JsonObject = buildJsonObject {
        put("kind", "agent")
        if (backend != null) put("backend", backend)
        putJsonObject("event") {
            put("kind", kind); put("callId", "legacy-muse-call")
            if (verb != null) put("verb", verb)
            if (target != null) put("target", target)
            if (detail != null) put("detail", detail)
        }
    }

    @Test fun oldMuseRowsAreEnrichedOnCompletionWithoutChangingTheirDetail() {
        val detail = """{"command":"rg --files src","description":"List files","output":"src/main.rs"}"""
        val row = coalesceTranscript(listOf(event("toolStart", "Bash", "", backend = "muse"),
            event("toolEnd", detail = detail)), defaultBackend = "codex")
            .filterIsInstance<ChatDisplayItem.Tool>().single().state
        assertEquals("rg --files src", row.target)
        assertEquals(detail, row.detail)
        assertEquals(ChatToolState.makeSnippet("Bash", detail), row.snippet)
        assertFalse(row.running)
    }

    @Test fun theStartRowsProviderWinsOverAnEndEventOrChatDefault() {
        val row = coalesceTranscript(listOf(event("toolStart", "Bash Input", "", backend = "codex"),
            event("toolEnd", detail = """{"command":"keep this output only"}""", backend = "muse")), defaultBackend = "muse")
            .filterIsInstance<ChatDisplayItem.Tool>().single().state
        assertEquals("Bash Input", row.verb)
        assertEquals("", row.target)
    }

    @Test fun orphanEndsUseTheEventProviderOrChatFallback() {
        val row = coalesceTranscript(listOf(event("toolEnd", "Write Todos", detail = "4 todos (revision 2)")), defaultBackend = "muse")
            .filterIsInstance<ChatDisplayItem.Tool>().single().state
        assertEquals("TodoWrite", row.verb)
        assertEquals("4 todos (revision 2)", row.target)
        assertEquals(listOf("| 4 todos (revision 2)"), row.snippet)
    }
}
