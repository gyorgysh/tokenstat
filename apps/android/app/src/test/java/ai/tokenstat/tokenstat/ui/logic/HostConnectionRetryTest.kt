// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.core.CoreFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostConnectionRetryTest {
    @Test fun fresh_tunnel_gets_woken_and_retried_before_an_error_is_shown() = runBlocking {
        var calls = 0
        var wakes = 0
        val pauses = mutableListOf<Long>()
        val answer = retryTunnelStartup(
            wakeTunnel = { wakes++ },
            pause = { pauses += it },
        ) {
            calls++
            if (calls < 3) throw CoreFailure("remote", "tunnel: tunnel is not connected")
            "allowed"
        }
        assertEquals("allowed", answer)
        assertEquals(3, calls)
        assertEquals(2, wakes)
        assertEquals(listOf(650L, 1300L), pauses)
    }

    @Test fun permission_or_cancellation_failures_are_never_retried() = runBlocking {
        var wakes = 0
        assertFalse(isTunnelStarting(CoreFailure("denied", "workspace access required")))
        assertTrue(isTunnelStarting(CoreFailure("remote", "could not reach host through the tunnel: tunnel is not connected")))
        try {
            retryTunnelStartup(wakeTunnel = { wakes++ }, pause = {}) {
                throw CoreFailure("denied", "workspace access required")
            }
            throw AssertionError("expected refusal")
        } catch (_: CoreFailure) {
            assertEquals(0, wakes)
        }
        try {
            retryTunnelStartup(wakeTunnel = { wakes++ }, pause = {}) {
                throw CancellationException("left screen")
            }
            throw AssertionError("expected cancellation")
        } catch (_: CancellationException) {
            assertEquals(0, wakes)
        }
    }
}
