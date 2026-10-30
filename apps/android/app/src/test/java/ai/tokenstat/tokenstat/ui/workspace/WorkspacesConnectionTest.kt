// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class WorkspacesConnectionTest {
    @Test fun explicit_host_choice_replaces_home_warmup_without_late_publication() {
        val session = WorkspacesConnectionState()
        val warmup = session.beginConnecting("saved-host")!!
        assertNull(session.beginConnecting("saved-host"))
        val chosen = session.beginConnecting("chosen-host", explicit = true)!!
        assertFalse(session.isCurrentConnection(warmup))
        session.finishConnecting(warmup)
        assertEquals("chosen-host", session.connectingPeer.value)
        assertTrue(session.isCurrentConnection(chosen))
        session.setLoadingFolders(true)
        assertTrue(session.loadingFolders.value)
        session.disconnect()
        assertFalse(session.isCurrentConnection(chosen))
        assertNull(session.connectingPeer.value)
        assertFalse(session.loadingFolders.value)
    }

    @Test fun git_status_refresh_keeps_loaded_sessions_and_chats() {
        val session = WorkspacesConnectionState()
        val sessions = JsonArray(listOf(JsonPrimitive("terminal")))
        val chats = JsonArray(listOf(JsonPrimitive("conversation")))
        session.setLists(JsonArray(emptyList()), sessions, chats)
        val folders = JsonArray(listOf(JsonPrimitive("project")))
        session.setFolders(folders)
        assertEquals(folders, session.folders.value)
        assertEquals(sessions, session.sessions.value)
        assertEquals(chats, session.chats.value)
    }

    @Test fun ten_hosts_keep_independent_work_and_disconnect_only_one() {
        val state = WorkspacesConnectionState()
        state.setAccountOwner("account-a")
        val peers = (1..10).map { "host-$it" }
        state.setKnownHosts(peers.toSet())
        peers.forEachIndexed { index, peer ->
            val ticket = state.beginBackground(peer, "account-a", nowMs = 1_000L)!!
            assertTrue(state.publishBackground(peer, "account-a", ticket,
                JsonArray(listOf(JsonPrimitive("folder-$peer"))),
                JsonArray(listOf(JsonPrimitive("terminal-$peer"))),
                JsonArray(listOf(JsonPrimitive("chat-$peer"))), nowMs = 1_000L + index))
            state.finishBackground(peer, "account-a", ticket, success = true, nowMs = 1_000L + index)
        }
        assertEquals(peers.toSet(), state.connectedHosts.value)
        assertTrue(state.activateConnectedHost(buildJsonObject { put("publicIdentity", "host-5") }))
        assertEquals("host-5", state.connectedPeer.value)
        state.disconnectHost("host-5")
        assertNull(state.connectedPeer.value)
        assertEquals(peers.toSet() - "host-5", state.connectedHosts.value)
        assertEquals(JsonArray(listOf(JsonPrimitive("folder-host-6"))), state.foldersFor("host-6"))
        assertEquals(JsonArray(listOf(JsonPrimitive("terminal-host-6"))), state.sessionsFor("host-6"))
        assertEquals(JsonArray(listOf(JsonPrimitive("chat-host-6"))), state.chatsFor("host-6"))
        state.setAccountOwner("account-b")
        assertTrue(state.connectedHosts.value.isEmpty())
        assertTrue(state.foldersFor("host-6").isEmpty())
    }

    @Test fun removed_host_and_previous_account_cannot_publish_late_background_work() {
        val state = WorkspacesConnectionState()
        state.setAccountOwner("account-a")
        state.setKnownHosts(setOf("allowed", "removed"))
        val removed = state.beginBackground("removed", "account-a")!!
        val allowed = state.beginBackground("allowed", "account-a")!!
        state.setKnownHosts(setOf("allowed"))
        assertFalse(state.publishBackground("removed", "account-a", removed,
            JsonArray(listOf(JsonPrimitive("late"))), JsonArray(emptyList()), JsonArray(emptyList())))
        state.setAccountOwner("account-b")
        assertFalse(state.publishBackground("allowed", "account-a", allowed,
            JsonArray(listOf(JsonPrimitive("late"))), JsonArray(emptyList()), JsonArray(emptyList())))
        assertTrue(state.connectedHosts.value.isEmpty())
    }
}
