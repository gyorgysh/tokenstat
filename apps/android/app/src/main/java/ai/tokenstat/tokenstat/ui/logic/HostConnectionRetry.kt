// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.core.CoreFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** A fresh process can dial before its relay session finishes starting. */
internal suspend fun <T> retryTunnelStartup(
    wakeTunnel: suspend () -> Unit,
    pause: suspend (Long) -> Unit = { delay(it) },
    call: suspend () -> T,
): T {
    var retries = 0
    while (true) {
        try {
            return call()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            if (retries >= 2 || !isTunnelStarting(error)) throw error
            retries++
            wakeTunnel()
            pause(if (retries == 1) 650 else 1300)
        }
    }
}

/** Retry only failures known to happen before a request reaches the host. */
internal fun isTunnelStarting(error: Exception): Boolean {
    if (error !is CoreFailure) return false
    val message = error.message.lowercase()
    return message.contains("tunnel is not connected") ||
        message.contains("tunnel session is not running")
}
