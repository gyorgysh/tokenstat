// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

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
}
