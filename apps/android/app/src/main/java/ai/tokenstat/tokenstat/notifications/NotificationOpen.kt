// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import android.content.Intent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

object NotificationOpen {
    data class Request(
        val machineID: String?,
        val waiting: Boolean,
        val offeredAtMs: Long,
    )

    const val PATIENCE_MS = 60_000L

    private val pending = MutableStateFlow<Request?>(null)
    val request: StateFlow<Request?> = pending.asStateFlow()

    fun parse(reason: String?, machine: String?, nowMs: Long = System.currentTimeMillis()): Request? {
        val clean = reason?.trim().orEmpty()
        if (!PushPayload.opensWork(clean)) return null
        return Request(
            machineID = machine?.trim().orEmpty().ifEmpty { null },
            waiting = PushPayload.waiting(clean),
            offeredAtMs = nowMs,
        )
    }

    fun offer(request: Request) {
        pending.value = request
    }

    fun offerFromIntent(intent: Intent?) {
        if (intent == null) return
        val request = parse(
            intent.getStringExtra(TokenstatMessagingService.EXTRA_REASON),
            intent.getStringExtra(TokenstatMessagingService.EXTRA_MACHINE),
        ) ?: return
        offer(request)
    }

    fun take(): Request? {
        val value = pending.value
        pending.value = null
        return value
    }

    fun dropIfStale(nowMs: Long = System.currentTimeMillis()): Boolean {
        val tap = pending.value ?: return false
        if (nowMs - tap.offeredAtMs < PATIENCE_MS) return false
        pending.value = null
        return true
    }

    fun pickHost(
        hosts: List<JsonObject>,
        machineID: String?,
        connectedPeerKey: String?,
    ): JsonObject? {
        if (machineID != null) {
            return hosts.firstOrNull {
                (it["id"] as? JsonPrimitive)?.contentOrNull == machineID
            }
        }
        if (connectedPeerKey != null) {
            hosts.firstOrNull {
                (it["publicIdentity"] as? JsonPrimitive)?.contentOrNull == connectedPeerKey
            }?.let { return it }
        }
        return hosts.firstOrNull()
    }

    fun pickChat(recents: List<JsonObject>, waiting: Boolean): JsonObject? {
        val ranked = recents
            .filter { !(it["id"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank() }
            .sortedByDescending { (it["lastMessageAtMs"] as? JsonPrimitive)?.longOrNull ?: 0L }
        if (waiting) {
            return ranked.firstOrNull {
                (it["needsAttention"] as? JsonPrimitive)?.booleanOrNull == true
            } ?: ranked.firstOrNull()
        }
        return ranked.firstOrNull {
            (it["lastMessageAuthor"] as? JsonPrimitive)?.contentOrNull == "agent"
        } ?: ranked.firstOrNull()
    }
}
