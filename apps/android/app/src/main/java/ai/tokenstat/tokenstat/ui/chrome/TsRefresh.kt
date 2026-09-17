// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.marks.UiSignals
import androidx.annotation.VisibleForTesting
import kotlinx.coroutines.delay

/// Per-screen refresh debounce matching `ClientRefresh.swift`: pulse the logo
/// always, skip the fetch inside five seconds, and stamp the key after work.
object TsRefresh {
    private const val minimumIntervalMs = 5_000L

    /// Reads the wall clock. Overridden in tests so the window can be
    /// advanced without waiting five real seconds.
    @VisibleForTesting
    internal var clock: () -> Long = System::currentTimeMillis

    @VisibleForTesting
    internal fun resetForTest() = lastRun.clear()

    private val lastRun = mutableMapOf<String, Long>()

    suspend fun run(key: String, work: suspend () -> Unit) = run(key, null, work)

    /// Run `work` for a pull to refresh, at most once per window per screen.
    /// `scope` names the signed-in account (origin plus identity, like
    /// `ClientRefresh.scoped`), so the first pull after an account switch is
    /// never swallowed by the outgoing account's timestamp. Null scope means
    /// no account is known yet, and the screen alone is all there is to name.
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
        // Stamped on the way out, not on the way in. A slow fetch would
        // otherwise spend most of its window running, and the pull somebody
        // makes right after it finishes would be the one that gets swallowed.
        lastRun[window] = clock()
    }
}
