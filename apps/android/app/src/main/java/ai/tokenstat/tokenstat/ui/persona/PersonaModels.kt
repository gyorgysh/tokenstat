// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import ai.tokenstat.tokenstat.ui.localization.L10n

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

data class ChatPersona(
    val id: String,
    val workspaceId: String?,
    val name: String,
    val systemPrompt: String,
    val seed: ULong,
) {
    companion object {
        fun blank(workspaceId: String? = null) = ChatPersona("", workspaceId, "", "", 0UL)
    }
}

data class ChatPersonaDraft(val name: String, val systemPrompt: String)

data class PersonaBackend(val id: String, val label: String, val installed: Boolean?)

fun faceSeedFor(persona: ChatPersona): ULong =
    if (persona.seed != 0UL) persona.seed
    else personaSeed(persona.name.ifEmpty { persona.systemPrompt })

val personaStartingPoints: List<Pair<String, String>> = listOf(
    "Reviewer" to L10n.text("android.personamodels.reviews_changes_carefully_says_what_is_wro.cc7172db"),
    "Explainer" to L10n.text("android.personamodels.explains_what_code_does_in_plain_language.0aac8304"),
    "Refactorer" to L10n.text("android.personamodels.finds_duplication_and_unclear_naming_propo.964ba2cf"),
    "Rubber duck" to L10n.text("android.personamodels.asks_questions_rather_than_answering_them.bf150882"),
)

private fun JsonObject.stringOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

private fun JsonObject.boolOrNull(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull

private fun JsonObject.uLongOrNull(key: String): ULong? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    primitive.longOrNull?.let { return it.toULong() }
    return primitive.contentOrNull?.toULongOrNull()
}

fun parseChatPersona(element: JsonElement?): ChatPersona? {
    val obj = element as? JsonObject ?: return null
    val id = obj.stringOrNull("id") ?: return null
    val workspaceRaw = obj["workspaceId"]
    return ChatPersona(
        id = id,
        workspaceId = if (workspaceRaw == null || workspaceRaw is JsonNull) null else obj.stringOrNull("workspaceId"),
        name = obj.stringOrNull("name") ?: "",
        systemPrompt = obj.stringOrNull("systemPrompt") ?: "",
        seed = obj.uLongOrNull("seed") ?: 0UL,
    )
}

fun parseChatPersonaList(element: JsonElement?): Pair<List<ChatPersona>, String?> {
    val obj = element as? JsonObject
    if (obj == null) {
        val personas = (element as? JsonArray).orEmpty().mapNotNull(::parseChatPersona)
        return personas to null
    }
    val personas = (obj["personas"] as? JsonArray).orEmpty().mapNotNull(::parseChatPersona)
    val defaultId = obj.stringOrNull("defaultId") ?: obj.stringOrNull("default_id")
    return personas to defaultId?.takeIf { it.isNotEmpty() }
}

fun parseChatPersonaDraft(element: JsonElement?): ChatPersonaDraft? {
    val obj = element as? JsonObject ?: return null
    return ChatPersonaDraft(
        name = obj.stringOrNull("name") ?: "",
        systemPrompt = obj.stringOrNull("systemPrompt") ?: "",
    )
}

fun parsePersonaBackends(element: JsonElement?): List<PersonaBackend> {
    val items = (element as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
    return items.mapNotNull { obj ->
        val id = obj.stringOrNull("id") ?: return@mapNotNull null
        if (id == "sh") return@mapNotNull null
        PersonaBackend(
            id = id,
            label = obj.stringOrNull("label") ?: obj.stringOrNull("name") ?: id,
            installed = obj.boolOrNull("installed"),
        )
    }
}

fun personaScopeParams(workspaceId: String): JsonObject = buildJsonObject { put("workspaceId", workspaceId) }

fun personaDefaultParams(workspaceId: String, personaId: String): JsonObject = buildJsonObject {
    put("workspaceId", workspaceId)
    put("personaId", personaId)
}

fun personaSaveParams(persona: ChatPersona, workspaceId: String?): JsonObject = buildJsonObject {
    put(
        "persona",
        buildJsonObject {
            put("id", persona.id)
            if (persona.workspaceId != null) put("workspaceId", persona.workspaceId) else put("workspaceId", JsonNull)
            put("name", persona.name)
            put("systemPrompt", persona.systemPrompt)
            put("seed", Json.parseToJsonElement(persona.seed.toString()))
        },
    )
    if (workspaceId != null) put("workspaceId", workspaceId)
}

fun personaDraftParams(brief: String, backend: String, name: String?): JsonObject = buildJsonObject {
    put("text", brief)
    put("backend", backend)
    if (!name.isNullOrBlank()) put("name", name)
}

fun personaRemoveParams(id: String): JsonObject = buildJsonObject { put("id", id) }
