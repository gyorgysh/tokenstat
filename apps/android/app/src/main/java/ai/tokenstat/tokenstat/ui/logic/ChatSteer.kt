// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

/// A note this device is holding until the host list echoes the same words.
/// `parkedAt` is the last list request started before the host took it.
data class SteerHold(val conversationId: String, val note: String, val parkedAt: Long = 0)

/// The list after a local note and a retired one have been applied.
data class SteerRows(
    val rows: List<JsonObject>,
    val held: SteerHold?,
    val retired: Set<String>,
)

/// Whether a short note can ride the next step, and how a chat list
/// keeps that note when the host answer arrives a moment later.
object ChatSteer {
    /// Host ids for the agents whose steps can carry a note.
    private val noteBackends = setOf("claude", "codex", "muse")

    /// A list requested after `since` was answered with the host's own copy.
    /// Only an older answer, already in flight, is painted over. Without this
    /// a note a step took before the next list would stay on screen all turn.
    fun answers(listRequest: Long, since: Long): Boolean = listRequest > since

    fun reconcile(rows: List<JsonObject>, held: SteerHold?, retired: Set<String>): SteerRows {
        val present = HashSet<String>()
        for (row in rows) {
            val id = idOf(row) ?: continue
            present.add(id)
        }
        var nextHeld = held?.takeIf { it.conversationId in present }
        val nextRetired = retired.filterTo(HashSet()) { it in present }
        val winning = nextHeld
        if (winning != null) nextRetired.remove(winning.conversationId)
        val painted = rows.map { row ->
            val id = idOf(row) ?: return@map row
            val hold = nextHeld
            if (hold != null && hold.conversationId == id) {
                if (noteOf(row) == hold.note.trim()) {
                    nextHeld = null
                    row
                } else {
                    withNote(row, hold.note)
                }
            } else if (id in nextRetired) {
                if (noteOf(row).isEmpty()) {
                    nextRetired.remove(id)
                    row
                } else {
                    withNote(row, null)
                }
            } else {
                row
            }
        }
        return SteerRows(painted, nextHeld, nextRetired.toSet())
    }

    /// The same row when the stored words already match, or when a strip
    /// finds no note to remove. A real change returns a new object.
    fun withNote(row: JsonObject, note: String?): JsonObject {
        val requested = note?.trim().orEmpty()
        if (requested.isEmpty()) {
            if (!row.containsKey("pendingSteer")) return row
            val map = row.toMutableMap()
            map.remove("pendingSteer")
            return JsonObject(map)
        }
        val stored = (row["pendingSteer"] as? JsonPrimitive)?.contentOrNull
        if (stored != null && stored.trim() == requested) return row
        val map = row.toMutableMap()
        map["pendingSteer"] = JsonPrimitive(requested)
        return JsonObject(map)
    }

    fun noteOf(row: JsonObject?): String {
        val value = row?.get("pendingSteer") as? JsonPrimitive ?: return ""
        return value.contentOrNull?.trim().orEmpty()
    }

    /// True when the composer may promise that the words ride the next step.
    /// A missing protocol does not promise, because the placeholder would be
    /// a claim this screen cannot keep.
    fun promisesNote(
        running: Boolean,
        stagedEmpty: Boolean,
        backend: String?,
        autonomy: String?,
        protocol: Long?,
        unsupported: Boolean,
    ): Boolean = carriesNote(running, stagedEmpty, backend, autonomy, unsupported) &&
        protocol != null && protocol >= HostContracts.STEER_MIN_PROTOCOL

    /// True when the send should ask the host to park a note. A missing
    /// protocol still tries. A known older protocol does not.
    fun canAttempt(
        running: Boolean,
        text: String,
        stagedEmpty: Boolean,
        backend: String?,
        autonomy: String?,
        protocol: Long?,
        unsupported: Boolean,
    ): Boolean {
        if (text.trim().isEmpty()) return false
        if (!carriesNote(running, stagedEmpty, backend, autonomy, unsupported)) return false
        if (protocol != null && protocol < HostContracts.STEER_MIN_PROTOCOL) return false
        return true
    }

    fun isSteerFallback(message: String?): Boolean = message == "This agent cannot take a note mid-turn." ||
        message == "This chat is not asking before tools, so a note cannot ride the next step." ||
        message == "This chat is not in the middle of a turn."

    fun isStillInTurn(message: String?): Boolean =
        message == "This chat is still in the middle of a turn."

    fun isUnknownMethod(code: String?, message: String?): Boolean {
        if (code == "unknown_method") return true
        val lower = message?.lowercase() ?: return false
        return lower.contains("unknown_method") || lower.contains("unknown method")
    }

    /// How long the open chat waits before asking again. A running turn or a
    /// parked note is checked sooner, so the note leaves as the turn ends.
    fun pollDelayMillis(running: Boolean, noteParked: Boolean): Long =
        if (running || noteParked) 400L else 2000L

    /// A missing autonomy counts as asking first. The host id is compared
    /// exactly, so a trailing space is a different agent.
    private fun carriesNote(
        running: Boolean,
        stagedEmpty: Boolean,
        backend: String?,
        autonomy: String?,
        unsupported: Boolean,
    ): Boolean {
        if (!running || !stagedEmpty || unsupported) return false
        if (backend !in noteBackends) return false
        if (backend == "muse") return true
        val mode = autonomy?.trim().orEmpty()
        return mode.isEmpty() || mode == "standard"
    }

    private fun idOf(row: JsonObject): String? {
        val id = (row["id"] as? JsonPrimitive)?.contentOrNull
        if (id.isNullOrEmpty()) return null
        return id
    }
}
