// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.core.CoreFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonObject

/** One visible inspection lease; the caller restarts it after navigation or resume. */
internal suspend fun pollChatInspection(
    read: suspend () -> JsonObject?,
    onRead: (JsonObject?) -> Unit,
    onFailure: () -> Unit,
) {
    while (true) {
        try {
            val next = read()
            currentCoroutineContext().ensureActive()
            onRead(next)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            onFailure()
            if (error is CoreFailure && error.code == "unknown_method") return
        }
        delay(5000)
    }
}
