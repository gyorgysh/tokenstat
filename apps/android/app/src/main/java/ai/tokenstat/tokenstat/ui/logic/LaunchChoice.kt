// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import android.content.Context
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// How the last conversation was set up, so the next one starts the same way.
///
/// Port of `LaunchChoice` and `chat.lastLaunchChoice.v1` in `ChatModel.swift`.
/// This is what "the default" actually means in this product: not a constant,
/// but whatever somebody was last working in. Somebody who works in Execute on
/// Bypass gets a new chat in Execute on Bypass, and does not have to set it
/// twice a day.
data class LaunchChoice(
    val backend: String,
    val model: String?,
    val effort: String?,
    val mode: String,
    val autonomy: String,
    /// Three states, all different: absent means nothing recorded yet and the
    /// workspace default applies, empty means the person chose no persona, and
    /// an id means that one.
    val personaId: String?,
)

/// The chat settings a new conversation opens with.
///
/// Never `plan`. The host's own `default_mode` is plan because a record with
/// no mode is the conservative reading of an unknown conversation, but a fresh
/// chat somebody just asked for is not unknown: planning at them is a turn
/// that does nothing they asked for. Twin of the `createChat` call in
/// `ChatModel.startChat`.
object LaunchDefaults {
    const val MODE = "execute"
    const val AUTONOMY = "standard"

    fun mode(saved: LaunchChoice?): String = saved?.mode?.ifBlank { null } ?: MODE

    /// An agent with no approval protocol of its own runs on Bypass or not at
    /// all, so it is put there whatever was last used.
    fun autonomy(saved: LaunchChoice?, bypassOnly: Boolean): String =
        if (bypassOnly) "bypass" else saved?.autonomy?.ifBlank { null } ?: AUTONOMY

    /// The agent a new chat opens on: the one last used if it is still
    /// installed, then Codex, then whatever else there is. `sh` is a shell
    /// rather than an agent and is never picked for somebody.
    fun backend(saved: LaunchChoice?, backends: List<JsonObject>): String {
        val available = backends.filter { backend ->
            val id = backend.launchId()
            id.isNotEmpty() && id != "sh" && backend.isInstalled()
        }
        val savedId = saved?.backend.orEmpty()
        return available.firstOrNull { it.launchId() == savedId }?.launchId()
            ?: available.firstOrNull { it.launchId() == "codex" }?.launchId()
            ?: available.firstOrNull()?.launchId()
            // An agent known to be uninstalled is never picked for somebody,
            // not even as the last resort before the hardcoded fallback.
            ?: backends.firstOrNull { it.launchId() != "sh" && it.isInstalled() }?.launchId()
            ?: "claude"
    }

    /// A saved model or effort only travels when the chosen agent offers it:
    /// they are agent-specific, and handing one to another agent is stale
    /// setup, not a preference.
    fun model(saved: LaunchChoice?, backend: JsonObject?): String? =
        saved?.model?.takeIf { it.isNotBlank() && it in backend.stringList("models") }

    fun effort(saved: LaunchChoice?, backend: JsonObject?): String? =
        saved?.effort?.takeIf { it.isNotBlank() && it in backend.stringList("efforts") }
}

private fun JsonObject.launchId(): String = this["id"]?.jsonPrimitive?.contentOrNull.orEmpty()

/// Absent is not "not installed": only an explicit false rules an agent out.
/// The safe cast, because a non-primitive value must not throw here.
private fun JsonObject.isInstalled(): Boolean =
    (this["installed"] as? JsonPrimitive)?.contentOrNull != "false"

private fun JsonObject?.stringList(key: String): List<String> =
    (this?.get(key) as? kotlinx.serialization.json.JsonArray)
        ?.mapNotNull { it.jsonPrimitive.contentOrNull }
        .orEmpty()

/// Where the last choice is kept. An interface so the rules above can be
/// tested without preferences.
interface LaunchChoiceStore {
    fun read(): LaunchChoice?
    fun write(choice: LaunchChoice)
}

/// One preference holding the whole record, the way the Apple client keeps one
/// encoded value under `chat.lastLaunchChoice.v1`.
class SharedPrefsLaunchChoice(context: Context) : LaunchChoiceStore {
    private val prefs = context.getSharedPreferences("ts.chat.launch", Context.MODE_PRIVATE)

    override fun read(): LaunchChoice? {
        val raw = prefs.getString(KEY, null) ?: return null
        return runCatching {
            val json = Json.parseToJsonElement(raw).jsonObject
            LaunchChoice(
                backend = json.text("backend").orEmpty(),
                model = json.text("model"),
                effort = json.text("effort"),
                mode = json.text("mode") ?: LaunchDefaults.MODE,
                autonomy = json.text("autonomy") ?: LaunchDefaults.AUTONOMY,
                personaId = json.text("personaId"),
            )
        }.getOrNull()
    }

    override fun write(choice: LaunchChoice) {
        val json = buildJsonObject {
            put("backend", choice.backend)
            choice.model?.let { put("model", it) }
            choice.effort?.let { put("effort", it) }
            put("mode", choice.mode)
            put("autonomy", choice.autonomy)
            // Empty, not absent: a conversation with no persona is a choice
            // worth carrying, and absent already means nothing recorded.
            put("personaId", choice.personaId.orEmpty())
        }
        prefs.edit().putString(KEY, json.toString()).apply()
    }

    private fun JsonObject.text(key: String): String? =
        this[key]?.jsonPrimitive?.contentOrNull

    private companion object {
        const val KEY = "lastLaunchChoice.v1"
    }
}

/// What a preview or a test uses.
class InMemoryLaunchChoice(private var choice: LaunchChoice? = null) : LaunchChoiceStore {
    override fun read(): LaunchChoice? = choice
    override fun write(choice: LaunchChoice) {
        this.choice = choice
    }
}
