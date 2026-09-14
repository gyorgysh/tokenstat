// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/// What a push may carry, and nothing else.
///
/// Mirrors `tokenstat-sync::push::Reason` and the Apple client's
/// `NotificationOpen.parse`: a fixed reason plus the id of the machine that
/// triggered it. The sentence is composed on this device from the reason, so
/// no folder name, prompt, path, or any other free text can travel in the
/// payload. Anything off the allowlist is dropped, never rendered.
object PushPayload {
    const val RUN_FINISHED = "run.finished"
    const val RUN_FAILED = "run.failed"
    const val RUN_NEEDS_INPUT = "run.needs_input"
    const val CHAT_FINISHED = "chat.finished"
    const val CHAT_FAILED = "chat.failed"
    const val SCREEN_ACCESS = "screen.access"
    const val TEST = "test"

    val KNOWN = setOf(
        RUN_FINISHED, RUN_FAILED, RUN_NEEDS_INPUT,
        CHAT_FINISHED, CHAT_FAILED, SCREEN_ACCESS, TEST,
    )

    private val json = Json { ignoreUnknownKeys = true }

    data class Delivery(val reason: String, val machine: String?)

    /// Read a delivery out of an FCM data map. Accepts the keys flat
    /// (`reason`, `machine`) or nested under `ts`, including a JSON-encoded
    /// `ts` string, the way the Apple client reads `userInfo["ts"]`.
    /// Returns null for unknown reasons, missing reasons, and anything that
    /// is not a string map, so a tap must not crash the app because a server
    /// delivered something this client did not write.
    fun parse(data: Map<String, String>): Delivery? {
        val nested = data["ts"]?.let { raw ->
            runCatching {
                json.parseToJsonElement(raw).jsonObject.entries.associate { (key, value) ->
                    key to (value.jsonPrimitive.contentOrNull ?: "")
                }
            }.getOrNull()
        }
        val reason = nested?.get("reason")?.trim().orEmpty()
            .ifEmpty { data["reason"]?.trim().orEmpty() }
        if (reason !in KNOWN) return null
        val machine = nested?.get("machine")?.trim().orEmpty()
            .ifEmpty { data["machine"]?.trim().orEmpty() }
            .ifEmpty { null }
        return Delivery(reason, machine)
    }

    /// Whether tapping this delivery should resolve a destination after the
    /// directory refreshes. Matches the Apple parse: chat reasons and a run
    /// waiting on input name a conversation to find, everything else only
    /// informs.
    fun opensWork(reason: String): Boolean = when (reason) {
        CHAT_FINISHED, CHAT_FAILED, RUN_NEEDS_INPUT -> true
        else -> false
    }

    fun waiting(reason: String): Boolean = reason == RUN_NEEDS_INPUT

    /// The banner text, composed here from the reason. The machine id is
    /// never shown: it names a key, not a computer.
    fun title(reason: String): String = when (reason) {
        RUN_FINISHED -> "Run finished"
        RUN_FAILED -> "Run failed"
        RUN_NEEDS_INPUT -> "Waiting for you"
        CHAT_FINISHED -> "Chat finished"
        CHAT_FAILED -> "Chat did not finish"
        SCREEN_ACCESS -> "Screen access"
        TEST -> "Notifications are on"
        else -> "tokenstat"
    }

    fun body(reason: String): String = when (reason) {
        RUN_FINISHED -> "An agent run finished on one of your machines."
        RUN_FAILED -> "An agent run did not finish cleanly."
        RUN_NEEDS_INPUT -> "An agent needs an answer to carry on."
        CHAT_FINISHED -> "An agent finished a turn."
        CHAT_FAILED -> "An agent turn did not finish cleanly."
        SCREEN_ACCESS -> "A device asks you to review screen permission."
        TEST -> "This is the only test notification."
        else -> "One of your agents needs attention."
    }
}
