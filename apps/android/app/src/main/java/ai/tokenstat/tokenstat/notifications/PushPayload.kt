// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import ai.tokenstat.tokenstat.ui.localization.L10n

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
        RUN_FINISHED -> L10n.text("android.pushpayload.run_finished.22488bd9")
        RUN_FAILED -> L10n.text("android.pushpayload.run_failed.97fddf2d")
        RUN_NEEDS_INPUT -> L10n.text("android.pushpayload.waiting_for_you.9f760ab2")
        CHAT_FINISHED -> L10n.text("android.pushpayload.chat_finished.a49ea476")
        CHAT_FAILED -> L10n.text("android.pushpayload.chat_did_not_finish.45962bbc")
        SCREEN_ACCESS -> L10n.text("android.pushpayload.screen_access.1a2a63ae")
        TEST -> L10n.text("android.pushpayload.notifications_are_on.ceaaed4b")
        else -> L10n.text("android.pushpayload.tokenstat.63d30539")
    }

    fun body(reason: String): String = when (reason) {
        RUN_FINISHED -> L10n.text("android.pushpayload.an_agent_run_finished_on_one_of_your_machi.bd252a8c")
        RUN_FAILED -> L10n.text("android.pushpayload.an_agent_run_did_not_finish_cleanly.30ab9f80")
        RUN_NEEDS_INPUT -> L10n.text("android.pushpayload.an_agent_needs_an_answer_to_carry_on.18bb10e5")
        CHAT_FINISHED -> L10n.text("android.pushpayload.an_agent_finished_a_turn.8ee8f80d")
        CHAT_FAILED -> L10n.text("android.pushpayload.an_agent_turn_did_not_finish_cleanly.29db4c02")
        SCREEN_ACCESS -> L10n.text("android.pushpayload.a_device_asks_you_to_review_screen_permiss.a24eb340")
        TEST -> L10n.text("android.pushpayload.this_is_the_only_test_notification.45933459")
        else -> L10n.text("android.pushpayload.one_of_your_agents_needs_attention.6137b683")
    }
}
