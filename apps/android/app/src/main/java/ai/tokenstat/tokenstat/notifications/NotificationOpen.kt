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

/// A tap on a notification, waiting to be opened.
///
/// Mirrors the Apple client's `NotificationOpen`: a push carries a reason
/// and a machine, never a destination, so the conversation is looked up over
/// the tunnel after the tap. The request lives here until the workspaces
/// screen that can open it fulfills it. Anything that never resolves is
/// dropped at patience, landing on the machine list, never a crash.
object NotificationOpen {
    data class Request(
        val machineID: String?,
        val waiting: Boolean,
        val offeredAtMs: Long,
    )

    /// How long a tap is retried before the app gives up and lands on a
    /// usable screen instead. Resolving one is not instant: the directory
    /// refreshes, a connect already in flight finishes, the machine the
    /// push named dials, and its recent chats load.
    const val PATIENCE_MS = 60_000L

    private val pending = MutableStateFlow<Request?>(null)
    val request: StateFlow<Request?> = pending.asStateFlow()

    /// Read a tap out of the extras the service wrote. Reasons that only
    /// inform (a finished run, the test ping) answer null, and so does
    /// anything the service did not write: a tap must not crash the app
    /// because something unexpected arrived in the intent.
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

    /// An attempt that could not resolve. True once the tap is stale, having
    /// dropped it, which is the caller's signal to land on a usable screen
    /// rather than keep chasing a destination that is not coming.
    fun dropIfStale(nowMs: Long = System.currentTimeMillis()): Boolean {
        val tap = pending.value ?: return false
        if (nowMs - tap.offeredAtMs < PATIENCE_MS) return false
        pending.value = null
        return true
    }

    /// The machine the tap names, looked up in the account directory. A
    /// named machine that is not there yet answers null so the tap is kept
    /// for the refresh still landing, exactly like the Apple lookup. Only a
    /// tap naming nothing falls back to the connected host, then the first.
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

    /// What needs the person, newest first. A waiting tap opens the chat
    /// asking for attention; a finished one opens the newest agent turn.
    /// Either falls back to the newest chat rather than to nothing. Mirrors
    /// `pickNotificationChat`: rows without an id are never a destination.
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
