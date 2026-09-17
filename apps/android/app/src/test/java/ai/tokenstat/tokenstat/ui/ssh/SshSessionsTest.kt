// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SshSessionsTest {
    private fun entry(id: String, hostId: String? = "host_1", alive: Boolean = true, ended: Boolean = false) =
        SshSessionEntry(id = id, hostId = hostId, label = "shell $id", alive = alive, locallyEnded = ended)

    @Test
    fun sessionEntryParsesSummary() {
        val parsed = SshSessionEntry.of(buildJsonObject {
            put("id", "s1")
            put("hostId", "host_9")
            put("label", "web")
            put("alive", true)
        })
        assertEquals(SshSessionEntry("s1", "host_9", "web", true), parsed)
        assertNull(SshSessionEntry.of(buildJsonObject { put("label", "no id") }))
        assertEquals(
            "Session",
            SshSessionEntry.of(buildJsonObject { put("id", "s2") })!!.label,
        )
    }

    @Test
    fun reconcileAdoptsUnknownSessions() {
        val out = reconcileSessions(
            current = listOf(entry("a")),
            held = listOf(entry("a"), entry("b")),
            closing = emptySet(),
        )
        assertEquals(listOf("a", "b"), out.map { it.id })
    }

    @Test
    fun reconcileSkipsClosingSessions() {
        // A close in flight must not adopt the session back.
        val out = reconcileSessions(
            current = emptyList(),
            held = listOf(entry("a")),
            closing = setOf("a"),
        )
        assertTrue(out.isEmpty())
    }

    @Test
    fun reconcileMarksForgottenSessionsEnded() {
        // The host reaps an ended shell before answering. The entry stays
        // until explicitly closed, so the final output can still be read.
        val out = reconcileSessions(
            current = listOf(entry("a")),
            held = emptyList(),
            closing = emptySet(),
        )
        assertEquals(1, out.size)
        assertTrue(out.single().locallyEnded)
    }

    @Test
    fun reconcileNeverRemovesOrResurrects() {
        val out = reconcileSessions(
            current = listOf(entry("a", ended = true)),
            held = listOf(entry("a")),
            closing = emptySet(),
        )
        assertEquals(1, out.size)
        assertTrue(out.single().locallyEnded)
    }

    @Test
    fun startupCommandsSkipsPlaceholdersAndOtherHosts() {
        val snippets = buildJsonArray {
            add(buildJsonObject {
                put("command", "uptime")
                put("runOnConnect", true)
                put("hostId", "host_1")
            })
            add(buildJsonObject {
                put("command", "deploy {{target}}")
                put("runOnConnect", true)
            })
            add(buildJsonObject {
                put("command", "other host")
                put("runOnConnect", true)
                put("hostId", "host_2")
            })
            add(buildJsonObject {
                put("command", "manual only")
                put("runOnConnect", false)
            })
        }
        assertEquals(listOf("uptime"), startupCommands("host_1", snippets))
        assertEquals(listOf("uptime"), startupCommands("host_1", snippets))
        assertTrue(startupCommands(null, snippets).isEmpty())
    }

    @Test
    fun sessionsStateAdoptsSelectsAndDismisses() {
        val state = SshConnectionState()
        assertNull(state.selected)
        state.adopt(entry("a"))
        assertEquals("a", state.selected?.id)
        // Adopting the same id twice lists it once.
        state.adopt(entry("a"))
        assertEquals(1, state.sessions.value.size)
        state.dismiss()
        assertNull(state.selected)
        // Dismiss keeps the shell: the entry stays for Open sessions.
        assertEquals(1, state.sessions.value.size)
        assertEquals(listOf("a"), state.sessionsFor("host_1").map { it.id })
        assertFalse(state.sessions.value.isEmpty())
    }
}
