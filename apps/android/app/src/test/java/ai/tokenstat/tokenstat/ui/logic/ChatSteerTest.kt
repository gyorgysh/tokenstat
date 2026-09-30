// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/// A mid-turn note has to survive a chat list that left a moment earlier,
/// and only a list requested after the mutation may release that protection.
class ChatSteerTest {
    private fun row(id: String, note: String? = null, title: String = "T"): JsonObject {
        val map = buildJsonObject {
            put("id", id)
            put("title", title)
        }.toMutableMap()
        if (note != null) map["pendingSteer"] = JsonPrimitive(note)
        return JsonObject(map)
    }

    @Test
    fun `an old echo keeps a hold until all older reads have finished`() {
        val server = row("c1", "hello")
        val result = ChatSteer.reconcile(listOf(server), mapOf("c1" to SteerHold("c1", "hello")), emptyMap())
        assertSame(server, result.rows[0])
        assertEquals(setOf("c1"), result.held.keys)
    }

    @Test
    fun `only a list asked for after the park speaks for the host`() {
        val hold = SteerHold("c1", "hello", parkedAt = 4)
        assertFalse(ChatSteer.answers(3, hold.parkedAt))
        assertFalse(ChatSteer.answers(4, hold.parkedAt))
        assertTrue(ChatSteer.answers(5, hold.parkedAt))
    }

    @Test
    fun `multiple old lists cannot erase or restore notes after an echo`() {
        val hold = mapOf("c1" to SteerHold("c1", "accepted", parkedAt = 4))
        val echo = ChatSteer.reconcile(listOf(row("c1", "accepted")), hold, emptyMap(), listRequest = 1)
        val older = ChatSteer.reconcile(listOf(row("c1")), echo.held, echo.retired, listRequest = 2)
        assertEquals("accepted", ChatSteer.noteOf(older.rows.single()))
        val cleared = ChatSteer.reconcile(listOf(row("c1")), emptyMap(), mapOf("c1" to 4L), listRequest = 1)
        val stale = ChatSteer.reconcile(listOf(row("c1", "removed")), cleared.held, cleared.retired, listRequest = 2)
        assertEquals("", ChatSteer.noteOf(stale.rows.single()))
        val fresh = ChatSteer.reconcile(listOf(row("c1", "peer note")), older.held, stale.retired, listRequest = 5)
        assertEquals("peer note", ChatSteer.noteOf(fresh.rows.single()))
    }

    @Test
    fun `parking notes in two conversations protects both`() {
        val holds = mapOf("c1" to SteerHold("c1", "first"), "c2" to SteerHold("c2", "second"))
        val result = ChatSteer.reconcile(listOf(row("c1"), row("c2")), holds, emptyMap())
        assertEquals(listOf("first", "second"), result.rows.map(ChatSteer::noteOf))
        assertEquals(holds, result.held)
    }

    @Test
    fun `one conversation retiring later does not hide another fresh peer note`() {
        val retired = mapOf("c1" to 1L, "c2" to 2L)
        val result = ChatSteer.reconcile(
            listOf(row("c1", "peer note"), row("c2", "removed")), emptyMap(), retired, listRequest = 2,
        )
        assertEquals("peer note", ChatSteer.noteOf(result.rows[0]))
        assertEquals("", ChatSteer.noteOf(result.rows[1]))
        assertEquals(mapOf("c2" to 2L), result.retired)
        val fresh = ChatSteer.reconcile(
            listOf(row("c1", "peer note"), row("c2", "new note")), emptyMap(), result.retired, listRequest = 3,
        )
        assertEquals(listOf("peer note", "new note"), fresh.rows.map(ChatSteer::noteOf))
        assertTrue(fresh.retired.isEmpty())
    }

    @Test
    fun `identical replacement notes invalidate old delivery after a list echo`() {
        val versions = SteerVersions()
        versions.changed("c1")
        val deliveryVersion = versions.version("c1")
        versions.changed("c1")
        val replacementVersion = versions.version("c1")
        val echoed = ChatSteer.reconcile(
            listOf(row("c1", "same words")), mapOf("c1" to SteerHold("c1", "same words", 1)),
            emptyMap(), listRequest = 2,
        )
        assertTrue(echoed.held.isEmpty())
        assertFalse(versions.current("c1", deliveryVersion))
        assertTrue(versions.current("c1", replacementVersion))
        versions.changed("c2")
        assertTrue(versions.current("c1", replacementVersion))
    }

    @Test
    fun `an old echo with surrounding space keeps the hold`() {
        val server = row("c1", " local ")
        val result = ChatSteer.reconcile(listOf(server), mapOf("c1" to SteerHold("c1", "local")), emptyMap())
        assertSame(server, result.rows[0])
        assertEquals(setOf("c1"), result.held.keys)
    }

    @Test
    fun `a hold is painted when the server has no note yet`() {
        val server = row("c1")
        val result = ChatSteer.reconcile(listOf(server), mapOf("c1" to SteerHold("c1", "local")), emptyMap())
        assertEquals("local", ChatSteer.noteOf(result.rows[0]))
        assertEquals("T", result.rows[0]["title"]?.let { (it as JsonPrimitive).content })
        assertEquals(SteerHold("c1", "local"), result.held["c1"])
    }

    @Test
    fun `a missing row from an old list keeps the hold`() {
        val other = row("other", "keep")
        val result = ChatSteer.reconcile(listOf(other), mapOf("c1" to SteerHold("c1", "local")), emptyMap())
        assertEquals(setOf("c1"), result.held.keys)
        assertSame(other, result.rows[0])
    }

    @Test
    fun `a retired note is stripped while the server still carries it`() {
        val server = row("c1", "old")
        val result = ChatSteer.reconcile(listOf(server), emptyMap(), mapOf("c1" to 0L))
        assertEquals("", ChatSteer.noteOf(result.rows[0]))
        assertFalse(result.rows[0].containsKey("pendingSteer"))
        assertEquals("T", (result.rows[0]["title"] as JsonPrimitive).content)
        assertEquals(setOf("c1"), result.retired.keys)
    }

    @Test
    fun `an empty row from an old list keeps retirement`() {
        val blank = row("c1", "   ")
        val missing = row("c2")
        val result = ChatSteer.reconcile(listOf(blank, missing), emptyMap(), mapOf("c1" to 0L, "c2" to 0L))
        assertFalse(result.rows[0].containsKey("pendingSteer"))
        assertSame(missing, result.rows[1])
        assertEquals(setOf("c1", "c2"), result.retired.keys)
    }

    @Test
    fun `a missing row from an old list keeps retirement`() {
        val other = row("other")
        val result = ChatSteer.reconcile(listOf(other), emptyMap(), mapOf("c1" to 0L))
        assertEquals(setOf("c1"), result.retired.keys)
        assertSame(other, result.rows[0])
    }

    @Test
    fun `a hold wins over retire for the same conversation`() {
        val server = row("c1")
        val result = ChatSteer.reconcile(listOf(server), mapOf("c1" to SteerHold("c1", "local")), mapOf("c1" to 0L))
        assertEquals("local", ChatSteer.noteOf(result.rows[0]))
        assertFalse("c1" in result.retired.keys)
        assertEquals(SteerHold("c1", "local"), result.held["c1"])
    }

    @Test
    fun `rows that are neither held nor retired stay the same instance`() {
        val held = row("c1")
        val other = row("c2", "keep")
        val result = ChatSteer.reconcile(listOf(held, other), mapOf("c1" to SteerHold("c1", "local")), emptyMap())
        assertSame(other, result.rows[1])
    }

    @Test
    fun `withNote keeps the row when the words already match`() {
        val stored = row("c1", " hello ")
        assertSame(stored, ChatSteer.withNote(stored, "hello"))
        assertSame(stored, ChatSteer.withNote(stored, " hello "))
        val bare = row("c1")
        assertSame(bare, ChatSteer.withNote(bare, null))
        assertSame(bare, ChatSteer.withNote(bare, ""))
        assertSame(bare, ChatSteer.withNote(bare, "   "))
        val painted = ChatSteer.withNote(bare, "hello")
        assertEquals("hello", ChatSteer.noteOf(painted))
        assertEquals("T", (painted["title"] as JsonPrimitive).content)
    }

    @Test
    fun `a non primitive note counts as empty and is stripped`() {
        val map = row("c1").toMutableMap()
        map["pendingSteer"] = buildJsonObject { put("x", 1) }
        val stored = JsonObject(map)
        assertEquals("", ChatSteer.noteOf(stored))
        val stripped = ChatSteer.withNote(stored, null)
        assertFalse(stripped.containsKey("pendingSteer"))
        assertTrue(stripped !== stored)
        assertEquals("T", (stripped["title"] as JsonPrimitive).content)
    }

    @Test
    fun `a retired non primitive note is stripped without releasing protection`() {
        val map = row("c1").toMutableMap()
        map["pendingSteer"] = buildJsonObject { put("x", 1) }
        val stored = JsonObject(map)
        val result = ChatSteer.reconcile(listOf(stored), emptyMap(), mapOf("c1" to 0L))
        assertFalse(result.rows[0].containsKey("pendingSteer"))
        assertEquals(setOf("c1"), result.retired.keys)
    }

    @Test
    fun `the composer promises a note only when the step can carry one`() {
        assertTrue(promise())
        assertTrue(attempt())
        assertFalse(promise(autonomy = "bypass"))
        assertFalse(attempt(autonomy = "bypass"))
        assertTrue(promise(backend = "muse", autonomy = "bypass"))
        assertTrue(attempt(backend = "muse", autonomy = "bypass"))
        assertTrue(promise(backend = "muse", autonomy = "plan"))
        assertTrue(attempt(backend = "muse", autonomy = "plan"))
        assertTrue(promise(backend = "muse", autonomy = null))
        assertTrue(attempt(backend = "muse", autonomy = null))
        assertTrue(promise(backend = "muse", autonomy = ""))
        assertTrue(attempt(backend = "muse", autonomy = ""))
        assertFalse(promise(backend = "muse "))
        assertFalse(attempt(backend = "muse "))
        assertTrue(promise(autonomy = ""))
        assertTrue(promise(autonomy = null))
        assertTrue(promise(autonomy = " standard "))
        assertTrue(attempt(autonomy = " standard "))
        assertTrue(promise(backend = "codex"))
        assertFalse(promise(backend = "other"))
        assertFalse(promise(backend = "claude "))
        assertFalse(promise(stagedEmpty = false))
        assertFalse(attempt(stagedEmpty = false))
        assertTrue(promise())
        assertFalse(attempt(text = "   "))
        assertFalse(promise(unsupported = true))
        assertFalse(attempt(unsupported = true))
        assertFalse(promise(running = false))
        assertFalse(attempt(running = false))
        assertFalse(promise(protocol = null))
        assertTrue(attempt(protocol = null))
        assertFalse(promise(protocol = 24))
        assertFalse(attempt(protocol = 24))
        assertTrue(promise(protocol = 25))
        assertTrue(attempt(protocol = 25))
    }

    @Test
    fun `fallback sentences are the three the host uses when a note cannot ride`() {
        assertTrue(ChatSteer.isSteerFallback("This agent cannot take a note mid-turn."))
        assertTrue(ChatSteer.isSteerFallback(
            "This chat is not asking before tools, so a note cannot ride the next step.",
        ))
        assertTrue(ChatSteer.isSteerFallback("This chat is not in the middle of a turn."))
        assertFalse(ChatSteer.isStillInTurn("This chat is not in the middle of a turn."))
        assertTrue(ChatSteer.isStillInTurn("This chat is still in the middle of a turn."))
        assertFalse(ChatSteer.isSteerFallback("This chat is still in the middle of a turn."))
        assertFalse(ChatSteer.isSteerFallback("Write the note you want on the next step."))
        assertFalse(ChatSteer.isSteerFallback(
            "That note is too long to ride the next step. Send it as its own message.",
        ))
    }

    @Test
    fun `an unknown method is the host code or the words in the raw message`() {
        assertTrue(ChatSteer.isUnknownMethod("unknown_method", "anything"))
        assertTrue(ChatSteer.isUnknownMethod(null, "Unknown Method"))
        assertTrue(ChatSteer.isUnknownMethod(null, "some unknown method here"))
        assertFalse(ChatSteer.isUnknownMethod(null, "Helper is out of date"))
        assertFalse(ChatSteer.isUnknownMethod("Unknown_Method", "Helper is out of date"))
    }

    @Test
    fun `a running turn or a parked note polls sooner`() {
        assertEquals(400L, ChatSteer.pollDelayMillis(running = true, noteParked = false))
        assertEquals(400L, ChatSteer.pollDelayMillis(running = false, noteParked = true))
        assertEquals(2000L, ChatSteer.pollDelayMillis(running = false, noteParked = false))
    }

    private fun promise(
        running: Boolean = true,
        stagedEmpty: Boolean = true,
        backend: String? = "claude",
        autonomy: String? = "standard",
        protocol: Long? = 25L,
        unsupported: Boolean = false,
    ) = ChatSteer.promisesNote(running, stagedEmpty, backend, autonomy, protocol, unsupported)

    private fun attempt(
        running: Boolean = true,
        text: String = "note",
        stagedEmpty: Boolean = true,
        backend: String? = "claude",
        autonomy: String? = "standard",
        protocol: Long? = 25L,
        unsupported: Boolean = false,
    ) = ChatSteer.canAttempt(running, text, stagedEmpty, backend, autonomy, protocol, unsupported)
}
