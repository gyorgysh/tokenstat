// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.NoteList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NoteEditsTest {
    @Test fun staleBodyEditCannotReplaceAnotherDevicesWriting() = runTest {
        val opened = NoteList.NoteCard("note", "Title", "Original", "backlog", 0, revision = 1)
        var saved = opened.copy(body = "Written on another device", revision = 2)
        suspend fun host(method: String, params: JsonObject): JsonObject {
            if (method == "todo.edit") require(params["expectedRevision"]?.jsonPrimitive?.longOrNull == saved.revision)
            saved = saved.copy(title = params["title"]!!.jsonPrimitive.content,
                body = params["notes"]!!.jsonPrimitive.content, revision = saved.revision!! + 1)
            return buildJsonObject { put("revision", saved.revision!!) }
        }
        assertTrue(runCatching { editNote(opened, "My title", "My unsaved body", ::host) }.isFailure)
        assertEquals("Written on another device", saved.body)
        assertEquals("Title", saved.title)
        editNote(saved, "My title", "My unsaved body", ::host)
        assertEquals("My unsaved body", saved.body)
        assertEquals(3L, saved.revision)
    }

    @Test fun missingRevisionNeverFallsBackToAnUncheckedEdit() = runTest {
        val legacy = NoteList.NoteCard("note", "Title", "Body", "backlog", 0)
        var called = false
        assertTrue(runCatching { editNote(legacy, "New", "New body") { _, _ ->
            called = true
            buildJsonObject {}
        } }.isFailure)
        assertFalse(called)
    }
}
