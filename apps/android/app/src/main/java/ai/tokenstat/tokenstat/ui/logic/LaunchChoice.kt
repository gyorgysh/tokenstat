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

data class LaunchChoice(
    val backend: String,
    val model: String?,
    val effort: String?,
    val mode: String,
    val autonomy: String,
    val personaId: String?,
)

object LaunchDefaults {
    const val MODE = "execute"
    const val AUTONOMY = "bypass"

    @Suppress("UNUSED_PARAMETER")
    fun mode(saved: LaunchChoice?): String = MODE

    @Suppress("UNUSED_PARAMETER")
    fun autonomy(saved: LaunchChoice?, bypassOnly: Boolean): String = AUTONOMY

    fun backend(saved: LaunchChoice?, backends: List<JsonObject>): String {
        val available = backends.filter { backend ->
            val id = backend.launchId()
            id.isNotEmpty() && id != "sh" && backend.isInstalled()
        }
        val savedId = saved?.backend.orEmpty()
        return available.firstOrNull { it.launchId() == savedId }?.launchId()
            ?: available.firstOrNull { it.launchId() == "codex" }?.launchId()
            ?: available.firstOrNull()?.launchId()
            ?: backends.firstOrNull { it.launchId() != "sh" && it.isInstalled() }?.launchId()
            ?: "claude"
    }

    fun model(saved: LaunchChoice?, backend: JsonObject?): String? =
        saved?.model?.takeIf { it.isNotBlank() && it in backend.stringList("models") }

    fun effort(saved: LaunchChoice?, backend: JsonObject?): String? =
        saved?.effort?.takeIf { it.isNotBlank() && it in backend.stringList("efforts") }
}

private fun JsonObject.launchId(): String = this["id"]?.jsonPrimitive?.contentOrNull.orEmpty()

private fun JsonObject.isInstalled(): Boolean =
    (this["installed"] as? JsonPrimitive)?.contentOrNull != "false"

private fun JsonObject?.stringList(key: String): List<String> =
    (this?.get(key) as? kotlinx.serialization.json.JsonArray)
        ?.mapNotNull { it.jsonPrimitive.contentOrNull }
        .orEmpty()

interface LaunchChoiceStore {
    fun read(): LaunchChoice?
    fun write(choice: LaunchChoice)
}

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

class InMemoryLaunchChoice(private var choice: LaunchChoice? = null) : LaunchChoiceStore {
    override fun read(): LaunchChoice? = choice
    override fun write(choice: LaunchChoice) {
        this.choice = choice
    }
}
