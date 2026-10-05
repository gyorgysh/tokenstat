// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ForegroundEffect
import ai.tokenstat.tokenstat.ui.home.HomeStores
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

/** Account machine records lack capabilities. Read them from the connected computer. */
@Composable
internal fun rememberWorkspaceHostProtocol(
    model: AppViewModel,
    peer: String,
    workspace: String,
    section: String?,
): Long? {
    val client by model.state.collectAsStateWithLifecycle()
    val owner = HomeStores.pinIdentity(client.account)
    var protocol by remember(model, owner, peer) { mutableStateOf<Long?>(null) }
    // Recheck on resume and navigation, including after the computer updates.
    ForegroundEffect(model, owner, peer, workspace, section) {
        if (owner.isNotEmpty() && peer.isNotBlank()) {
            probeWorkspaceHostProtocol(
                read = { model.workspaceSection(peer, "protocol", buildJsonObject {}) },
                onRead = { protocol = it },
            )
        }
    }
    return protocol
}

/** A failed tunnel read must not hide newer controls for the rest of the visit. */
internal suspend fun probeWorkspaceHostProtocol(
    read: suspend () -> JsonElement?,
    onRead: (Long) -> Unit,
) {
    var retryDelay = 1_000L
    while (true) {
        currentCoroutineContext().ensureActive()
        val response = try {
            read()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
        // A native read can finish after navigation has cancelled its coroutine.
        currentCoroutineContext().ensureActive()
        val protocol = HostContracts.protocolOf(response as? JsonObject)
        if (protocol != null) {
            onRead(protocol)
            return
        }
        delay(retryDelay)
        retryDelay = (retryDelay * 2).coerceAtMost(10_000L)
    }
}
