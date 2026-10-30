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
        state.disconnectHost("peer-a")
        assertEquals(setOf("peer-b"), state.connectedHosts.value)
        assertTrue(state.activateConnectedHost(host("peer-b")))
        assertEquals("Beta", (state.folders.value.single() as kotlinx.serialization.json.JsonObject).str("name"))

        state.setKnownHosts(emptySet())
        assertTrue(state.connectedHosts.value.isEmpty())
        assertFalse(state.activateConnectedHost(host("peer-b")))
        assertFalse(state.activateConnectedHost(host("peer-a")))

        state.setAccountOwner("account-two")
        assertFalse(state.publishBackground("peer-c", "account-one", JsonArray(emptyList()), JsonArray(emptyList()), JsonArray(emptyList())))
        assertTrue(state.backgroundConnecting.value.isEmpty())
        assertTrue(state.connectedHosts.value.isEmpty())
    }

    @Test fun retainedHostRefreshKeepsWorkUntilSuccessAndClearsItWhenAccessIsRevoked() {
        val state = WorkspacesConnectionState()
        state.setAccountOwner("account-one")
        assertTrue(state.beginBackground("peer-b", "account-one", nowMs = 100))
        assertTrue(state.publishBackground("peer-b", "account-one", JsonArray(listOf(folder("Old"))),
            JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 100))
        state.finishBackground("peer-b", "account-one", success = true, nowMs = 100)

        assertFalse(state.beginBackground("peer-b", "account-one", nowMs = 60_099))
        assertTrue(state.beginBackground("peer-b", "account-one", nowMs = 60_100))
        state.finishBackground("peer-b", "account-one", success = false, nowMs = 60_100)
        assertEquals(setOf("peer-b"), state.staleHosts.value)
        assertEquals("Old", (state.foldersFor("peer-b").single() as kotlinx.serialization.json.JsonObject).str("name"))
        assertFalse(state.beginBackground("peer-b", "account-one", nowMs = 62_099))
        assertTrue(state.beginBackground("peer-b", "account-one", nowMs = 62_100))
        assertTrue(state.publishBackground("peer-b", "account-one", JsonArray(listOf(folder("Fresh"))),
            JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 62_100))
        state.finishBackground("peer-b", "account-one", success = true, nowMs = 62_100)
        assertTrue(state.staleHosts.value.isEmpty())
        assertEquals("Fresh", (state.foldersFor("peer-b").single() as kotlinx.serialization.json.JsonObject).str("name"))

        assertTrue(state.beginBackground("peer-b", "account-one", nowMs = 122_100))
        state.beginConnecting("peer-b", explicit = true)
        state.finishBackground("peer-b", "account-one", success = false, nowMs = 122_100)
        assertTrue(state.staleHosts.value.isEmpty())
        assertTrue(state.connectedHosts.value.contains("peer-b"))
        state.finishConnecting(state.beginConnecting("peer-b", explicit = true)!!)
        assertTrue(state.beginBackground("peer-b", "account-one", nowMs = 122_100))
        state.dropBackgroundHost("peer-b", "account-one")
        state.finishBackground("peer-b", "account-one", success = false, nowMs = 122_100)
        assertTrue(state.connectedHosts.value.isEmpty())
        assertTrue(state.foldersFor("peer-b").isEmpty())
    }
}
