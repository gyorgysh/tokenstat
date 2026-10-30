// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspacesConnectionStateTest {
    private fun host(peer: String) = buildJsonObject { put("publicIdentity", peer) }
    private fun folder(name: String) = buildJsonObject {
        put("id", "same-raw-id")
        put("name", name)
    }

    @Test fun hostSnapshotsKeepOverlappingFolderIdsAndClearOnAccountChange() {
        val state = WorkspacesConnectionState()
        state.setAccountOwner("account-one")
        state.setHost(host("peer-a"))
        state.setConnected("peer-a", true)
        state.setLists(JsonArray(listOf(folder("Alpha"))), JsonArray(emptyList()), JsonArray(emptyList()))
        state.setHost(host("peer-b"))
        state.setConnected("peer-b", true)
        state.setLists(JsonArray(listOf(folder("Beta"))), JsonArray(emptyList()), JsonArray(emptyList()))

        assertEquals(setOf("peer-a", "peer-b"), state.connectedHosts.value)
        assertTrue(state.activateConnectedHost(host("peer-a")))
        assertEquals("Alpha", (state.folders.value.single() as kotlinx.serialization.json.JsonObject).str("name"))
        assertTrue(state.activateConnectedHost(host("peer-b")))
        assertEquals("Beta", (state.folders.value.single() as kotlinx.serialization.json.JsonObject).str("name"))

        state.disconnect()
        assertEquals(setOf("peer-a"), state.connectedHosts.value)
        assertFalse(state.activateConnectedHost(host("peer-b")))
        assertTrue(state.activateConnectedHost(host("peer-a")))
        state.setAccountOwner("account-two")
        assertTrue(state.connectedHosts.value.isEmpty())
        assertFalse(state.activateConnectedHost(host("peer-a")))
    }

    @Test fun backgroundHostsAreIndependentAndRespectCooldownAndForegroundOwner() {
        val state = WorkspacesConnectionState()
        state.setAccountOwner("account-one")
        state.setHost(host("peer-a"))
        state.setConnected("peer-a", true)
        state.setLists(JsonArray(listOf(folder("Alpha"))), JsonArray(emptyList()), JsonArray(emptyList()))

        assertTrue(state.beginBackground("peer-b", "account-one", nowMs = 100))
        assertTrue(state.beginBackground("peer-c", "account-one", nowMs = 100))
        assertFalse(state.beginBackground("peer-b", "account-one", nowMs = 100))
        assertFalse(state.publishBackground("peer-a", "account-one", JsonArray(emptyList()), JsonArray(emptyList()), JsonArray(emptyList())))
        assertTrue(state.publishBackground("peer-b", "account-one", JsonArray(listOf(folder("Beta"))), JsonArray(emptyList()), JsonArray(emptyList())))
        assertEquals("Alpha", (state.folders.value.single() as kotlinx.serialization.json.JsonObject).str("name"))
        state.finishBackground("peer-b", "account-one", success = true, nowMs = 100)
        state.finishBackground("peer-c", "account-one", success = false, nowMs = 100)
        assertFalse(state.beginBackground("peer-c", "account-one", nowMs = 2_099))
        assertTrue(state.beginBackground("peer-c", "account-one", nowMs = 2_100))
        assertEquals(setOf("peer-a", "peer-b"), state.connectedHosts.value)
        assertTrue(state.activateConnectedHost(host("peer-b")))
        assertEquals("Beta", (state.folders.value.single() as kotlinx.serialization.json.JsonObject).str("name"))

        state.setAccountOwner("account-two")
        assertFalse(state.publishBackground("peer-c", "account-one", JsonArray(emptyList()), JsonArray(emptyList()), JsonArray(emptyList())))
        assertTrue(state.backgroundConnecting.value.isEmpty())
        assertTrue(state.connectedHosts.value.isEmpty())
    }
}
