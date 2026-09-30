// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/// A mid-turn note has to survive a chat list that left a moment earlier,
/// and it has to disappear once the host echoes it or the person drops it.
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
    fun `a hold clears when the server echoes the same words`() {
        val server = row("c1", "hello")
        val result = ChatSteer.reconcile(listOf(server), SteerHold("c1", "hello"), emptySet())
        assertSame(server, result.rows[0])
        assertNull(result.held)
    }

    @Test
    fun `only a list asked for after the park speaks for the host`() {
        val hold = SteerHold("c1", "hello", parkedAt = 4)
        assertFalse(ChatSteer.answers(3, hold.parkedAt))
        assertFalse(ChatSteer.answers(4, hold.parkedAt))
        assertTrue(ChatSteer.answers(5, hold.parkedAt))
    }

    @Test
    fun `a hold clears when the server echo only differs by surrounding space`() {
        val server = row("c1", " local ")
        val result = ChatSteer.reconcile(listOf(server), SteerHold("c1", "local"), emptySet())
        assertSame(server, result.rows[0])
        assertNull(result.held)
    }

    @Test
    fun `a hold is painted when the server has no note yet`() {
        val server = row("c1")
        val result = ChatSteer.reconcile(listOf(server), SteerHold("c1", "local"), emptySet())
        assertEquals("local", ChatSteer.noteOf(result.rows[0]))
        assertEquals("T", result.rows[0]["title"]?.let { (it as JsonPrimitive).content })
        assertEquals(SteerHold("c1", "local"), result.held)
    }

    @Test
    fun `a hold is dropped when its conversation is missing`() {
        val other = row("other", "keep")
        val result = ChatSteer.reconcile(listOf(other), SteerHold("c1", "local"), emptySet())
        assertNull(result.held)
        assertSame(other, result.rows[0])
    }

    @Test
    fun `a retired note is stripped while the server still carries it`() {
        val server = row("c1", "old")
        val result = ChatSteer.reconcile(listOf(server), null, setOf("c1"))
        assertEquals("", ChatSteer.noteOf(result.rows[0]))
        assertFalse(result.rows[0].containsKey("pendingSteer"))
        assertEquals("T", (result.rows[0]["title"] as JsonPrimitive).content)
        assertEquals(setOf("c1"), result.retired)
    }

    @Test
    fun `a retired id is dropped when the server note is empty`() {
        val blank = row("c1", "   ")
        val missing = row("c2")
        val result = ChatSteer.reconcile(listOf(blank, missing), null, setOf("c1", "c2"))
        assertSame(blank, result.rows[0])
        assertSame(missing, result.rows[1])
        assertTrue(result.retired.isEmpty())
    }

    @Test
    fun `a retired id is dropped when the conversation is missing`() {
        val other = row("other")
        val result = ChatSteer.reconcile(listOf(other), null, setOf("c1"))
        assertTrue(result.retired.isEmpty())
        assertSame(other, result.rows[0])
    }

    @Test
    fun `a hold wins over retire for the same conversation`() {
        val server = row("c1")
        val result = ChatSteer.reconcile(listOf(server), SteerHold("c1", "local"), setOf("c1"))
        assertEquals("local", ChatSteer.noteOf(result.rows[0]))
        assertFalse("c1" in result.retired)
        assertEquals(SteerHold("c1", "local"), result.held)
    }

    @Test
    fun `rows that are neither held nor retired stay the same instance`() {
        val held = row("c1")
        val other = row("c2", "keep")
        val result = ChatSteer.reconcile(listOf(held, other), SteerHold("c1", "local"), emptySet())
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
    fun `a retired non primitive note stays the same row and leaves retirement`() {
        val map = row("c1").toMutableMap()
        map["pendingSteer"] = buildJsonObject { put("x", 1) }
        val stored = JsonObject(map)
        val result = ChatSteer.reconcile(listOf(stored), null, setOf("c1"))
        assertSame(stored, result.rows[0])
        assertTrue(result.retired.isEmpty())
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
