// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SshTunnelStateTest {
    @Test
    fun missingStatusReadsAsOff() {
        assertEquals(TunnelState.Off, tunnelStateOf(null))
        assertNull(TunnelState.Off.message())
    }

    @Test
    fun disabledTunnelIsSilent() {
        val state = tunnelStateOf(buildJsonObject {
            put("tunnel", false)
            put("tunnelOnline", false)
        })
        assertEquals(TunnelState.Off, state)
        assertNull(state.message())
    }

    @Test
    fun enabledButOfflineNamesTheError() {
        val state = tunnelStateOf(buildJsonObject {
            put("tunnel", true)
            put("tunnelOnline", false)
            put("tunnelError", "relay refused: revoked token")
        })
        assertTrue(state is TunnelState.NotConnected)
        assertEquals(
            "Remote reach is on, but the tunnel is not connected: relay refused: revoked token",
            state.message(),
        )
    }

    @Test
    fun enabledButOfflineWithoutErrorWaits() {
        val state = tunnelStateOf(buildJsonObject {
            put("tunnel", true)
            put("tunnelOnline", false)
        })
        assertEquals(TunnelState.NotConnected(null), state)
        assertEquals(
            "Remote reach is on, but the tunnel has not connected yet. It retries automatically.",
            state.message(),
        )
    }

    @Test
    fun planGateHasItsOwnWords() {
        val state = tunnelStateOf(buildJsonObject {
            put("tunnel", true)
            put("tunnelOnline", false)
            put("tunnelError", "not_on_this_plan")
        })
        assertEquals(TunnelState.PlanExpired, state)
        assertEquals(
            "Your plan no longer includes remote reach. The relay is refusing this machine until the plan is restored.",
            state.message(),
        )
    }

    @Test
    fun onlineButUnregisteredWaitsForTheDirectory() {
        val state = tunnelStateOf(buildJsonObject {
            put("tunnel", true)
            put("tunnelOnline", true)
            put("tunnelRegistered", false)
        })
        assertEquals(TunnelState.Unregistered, state)
        assertEquals(
            "This machine is on the tunnel, but the account directory does not list it yet. It will retry registration automatically.",
            state.message(),
        )
    }

    @Test
    fun upTunnelIsSilent() {
        val state = tunnelStateOf(buildJsonObject {
            put("tunnel", true)
            put("tunnelOnline", true)
            put("tunnelRegistered", true)
        })
        assertEquals(TunnelState.Up, state)
        assertNull(state.message())
    }

    @Test
    fun unansweredOnlineReadsAsNotConnected() {
        // The toggle is on and nothing says the session is up: that is the
        // state this banner exists for, not silence.
        val state = tunnelStateOf(buildJsonObject { put("tunnel", true) })
        assertTrue(state is TunnelState.NotConnected)
    }
}
