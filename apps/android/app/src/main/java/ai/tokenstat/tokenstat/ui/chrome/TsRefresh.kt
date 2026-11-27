// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.marks.UiSignals
import androidx.annotation.VisibleForTesting
import kotlinx.coroutines.delay

object TsRefresh {
    private const val minimumIntervalMs = 5_000L

    @VisibleForTesting
    internal var clock: () -> Long = System::currentTimeMillis

    @VisibleForTesting
    internal fun resetForTest() = lastRun.clear()

    private val lastRun = mutableMapOf<String, Long>()

    suspend fun run(key: String, work: suspend () -> Unit) = run(key, null, work)

    suspend fun run(key: String, scope: String?, work: suspend () -> Unit) {
        UiSignals.beganRefreshing()
        val window = if (scope.isNullOrEmpty()) key else "$scope|$key"
        val now = clock()
        val previous = lastRun[window] ?: 0L
        if (now - previous < minimumIntervalMs) {
            delay(450)
            return
        }
        work()
        lastRun[window] = clock()
    }
}
