// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.marks.UiSignals
import kotlinx.coroutines.delay

/// Per-screen refresh debounce matching `ClientRefresh.swift`: pulse the logo
/// always, skip the fetch inside five seconds, and stamp the key after work.
object TsRefresh {
    private const val minimumIntervalMs = 5_000L
    private val lastRun = mutableMapOf<String, Long>()

    suspend fun run(key: String, work: suspend () -> Unit) {
        UiSignals.beganRefreshing()
        val now = System.currentTimeMillis()
        val previous = lastRun[key] ?: 0L
        if (now - previous < minimumIntervalMs) {
            delay(450)
            return
        }
        work()
        lastRun[key] = System.currentTimeMillis()
    }
}
