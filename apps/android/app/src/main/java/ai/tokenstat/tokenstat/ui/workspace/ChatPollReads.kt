// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

internal suspend fun chatPollReads(
    events: suspend () -> Boolean,
    status: suspend () -> Unit,
): Boolean = coroutineScope {
    val more = async { events() }
    status()
    more.await()
}
