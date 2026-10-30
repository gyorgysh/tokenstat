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

        val b = state.beginBackground("peer-b", "account-one", nowMs = 100)!!
        val c = state.beginBackground("peer-c", "account-one", nowMs = 100)!!
        assertEquals(null, state.beginBackground("peer-b", "account-one", nowMs = 100))
        assertFalse(state.publishBackground("peer-a", "account-one", b, JsonArray(emptyList()), JsonArray(emptyList()), JsonArray(emptyList())))
        assertTrue(state.publishBackground("peer-b", "account-one", b, JsonArray(listOf(folder("Beta"))), JsonArray(emptyList()), JsonArray(emptyList())))
        assertEquals("Alpha", (state.folders.value.single() as kotlinx.serialization.json.JsonObject).str("name"))
        state.finishBackground("peer-b", "account-one", b, success = true, nowMs = 100)
        state.finishBackground("peer-c", "account-one", c, success = false, nowMs = 100)
        assertEquals(null, state.beginBackground("peer-c", "account-one", nowMs = 2_099))
        val retry = state.beginBackground("peer-c", "account-one", nowMs = 2_100)!!
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
        assertFalse(state.publishBackground("peer-c", "account-one", retry, JsonArray(emptyList()), JsonArray(emptyList()), JsonArray(emptyList())))
        assertTrue(state.backgroundConnecting.value.isEmpty())
        assertTrue(state.connectedHosts.value.isEmpty())
    }

    @Test fun retainedHostRefreshKeepsWorkUntilSuccessAndClearsItWhenAccessIsRevoked() {
        val state = WorkspacesConnectionState()
        state.setAccountOwner("account-one")
        val first = state.beginBackground("peer-b", "account-one", nowMs = 100)!!
        assertTrue(state.publishBackground("peer-b", "account-one", first, JsonArray(listOf(folder("Old"))),
            JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 100))
        state.finishBackground("peer-b", "account-one", first, success = true, nowMs = 100)

        assertEquals(null, state.beginBackground("peer-b", "account-one", nowMs = 60_099))
        val failed = state.beginBackground("peer-b", "account-one", nowMs = 500, forceRefresh = true)!!
        state.finishBackground("peer-b", "account-one", failed, success = false, nowMs = 500)
        val cancelled = state.beginBackground("peer-b", "account-one", nowMs = 501, forceRefresh = true)!!
        state.finishBackground("peer-b", "account-one", cancelled, success = false, nowMs = 501, cancelled = true)
        val stale = state.beginBackground("peer-b", "account-one", nowMs = 60_100)!!
        state.finishBackground("peer-b", "account-one", stale, success = false, nowMs = 60_100)
        assertEquals(setOf("peer-b"), state.staleHosts.value)
        assertEquals("Old", (state.foldersFor("peer-b").single() as kotlinx.serialization.json.JsonObject).str("name"))
        assertEquals(null, state.beginBackground("peer-b", "account-one", nowMs = 64_099))
        val fresh = state.beginBackground("peer-b", "account-one", nowMs = 64_100)!!
        assertTrue(state.publishBackground("peer-b", "account-one", fresh, JsonArray(listOf(folder("Fresh"))),
            JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 64_100))
        state.finishBackground("peer-b", "account-one", fresh, success = true, nowMs = 64_100)
        assertTrue(state.staleHosts.value.isEmpty())
        assertEquals("Fresh", (state.foldersFor("peer-b").single() as kotlinx.serialization.json.JsonObject).str("name"))

        val takenOver = state.beginBackground("peer-b", "account-one", nowMs = 124_100)!!
        state.beginConnecting("peer-b", explicit = true)
        state.finishBackground("peer-b", "account-one", takenOver, success = false, nowMs = 124_100)
        assertTrue(state.staleHosts.value.isEmpty())
        assertTrue(state.connectedHosts.value.contains("peer-b"))
        state.finishConnecting(state.beginConnecting("peer-b", explicit = true)!!)
        val denied = state.beginBackground("peer-b", "account-one", nowMs = 124_100)!!
        state.dropBackgroundHost("peer-b", "account-one", denied)
        state.finishBackground("peer-b", "account-one", denied, success = false, nowMs = 124_100)
        assertTrue(state.connectedHosts.value.isEmpty())
        assertTrue(state.foldersFor("peer-b").isEmpty())
    }

    @Test fun lateReplyCannotReplaceAReconnectedHostOrCrossAnAccountRestart() {
        val state = WorkspacesConnectionState()
        val peers = (1..10).map { "peer-$it" }
        state.setAccountOwner("account-one")
        state.setKnownHosts(peers.toSet())
        val tickets = peers.associateWith { state.beginBackground(it, "account-one", nowMs = 100)!! }

        state.disconnectHost("peer-1")
        val replacement = state.beginBackground("peer-1", "account-one", nowMs = 101)!!
        assertFalse(state.isCurrentBackground("peer-1", "account-one", tickets.getValue("peer-1")))
        assertFalse(state.dropBackgroundHost("peer-1", "account-one", tickets.getValue("peer-1")))
        assertFalse(state.publishBackground("peer-1", "account-one", tickets.getValue("peer-1"),
            JsonArray(listOf(folder("Old"))), JsonArray(emptyList()), JsonArray(emptyList())))
        state.finishBackground("peer-1", "account-one", tickets.getValue("peer-1"), success = false, nowMs = 101)
        assertTrue("peer-1" in state.backgroundConnecting.value)
        assertTrue(state.isCurrentBackground("peer-1", "account-one", replacement))
        assertTrue(state.publishBackground("peer-1", "account-one", replacement,
            JsonArray(listOf(folder("New"))), JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 101))
        state.finishBackground("peer-1", "account-one", replacement, success = true, nowMs = 101)

        for (peer in peers.drop(1)) {
            val ticket = tickets.getValue(peer)
            assertTrue(state.publishBackground(peer, "account-one", ticket,
                JsonArray(listOf(folder(peer))), JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 101))
            state.finishBackground(peer, "account-one", ticket, success = true, nowMs = 101)
        }
        assertEquals(peers.toSet(), state.connectedHosts.value)
        assertEquals("New", (state.foldersFor("peer-1").single() as kotlinx.serialization.json.JsonObject).str("name"))

        val toggleOld = state.beginBackground("peer-2", "account-one", nowMs = 102, forceRefresh = true)!!
        state.invalidateBackground("peer-2")
        val toggleNew = state.beginBackground("peer-2", "account-one", nowMs = 103, forceRefresh = true)!!
        assertFalse(state.publishBackground("peer-2", "account-one", toggleOld,
            JsonArray(listOf(folder("Toggled off"))), JsonArray(emptyList()), JsonArray(emptyList())))
        state.finishBackground("peer-2", "account-one", toggleOld, success = false)
        assertTrue(state.publishBackground("peer-2", "account-one", toggleNew,
            JsonArray(listOf(folder("Toggled on"))), JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 103))
        state.finishBackground("peer-2", "account-one", toggleNew, success = true, nowMs = 103)

        val oldAccountTicket = state.beginBackground("peer-1", "account-one", nowMs = 102, forceRefresh = true)!!
        state.setAccountOwner("account-two")
        state.setAccountOwner("account-one")
        state.setKnownHosts(peers.toSet())
        val newAccountTicket = state.beginBackground("peer-1", "account-one", nowMs = 103)!!
        assertFalse(state.publishBackground("peer-1", "account-one", oldAccountTicket,
            JsonArray(listOf(folder("Leaked"))), JsonArray(emptyList()), JsonArray(emptyList())))
        state.finishBackground("peer-1", "account-one", oldAccountTicket, success = true)
        assertTrue("peer-1" in state.backgroundConnecting.value)
        assertTrue(state.publishBackground("peer-1", "account-one", newAccountTicket,
            JsonArray(listOf(folder("Current"))), JsonArray(emptyList()), JsonArray(emptyList()), nowMs = 103))
        assertEquals("Current", (state.foldersFor("peer-1").single() as kotlinx.serialization.json.JsonObject).str("name"))
    }
}
