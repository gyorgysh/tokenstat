// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

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

/// A voice, not a launcher. Port of `ChatPersona`.
///
/// What is left after the launcher fields moved to the conversation is what
/// the word means: a name and a brief, plus the seed its face is drawn from.
/// A nil workspace id is a shared persona, available in every folder.
data class ChatPersona(
    val id: String,
    val workspaceId: String?,
    val name: String,
    val systemPrompt: String,
    val seed: ULong,
) {
    companion object {
        /// Zero asks the host for the usual seed, derived from the id it is
        /// about to mint. A face cannot be settled before the persona exists.
        fun blank(workspaceId: String? = null) = ChatPersona("", workspaceId, "", "", 0UL)
    }
}

/// A generated starting point, before anybody has agreed to keep it. Port of
/// `ChatPersonaDraft`: generated text goes into a form, and only a press turns
/// it into a persona.
data class ChatPersonaDraft(val name: String, val systemPrompt: String)

/// Chat-only backend metadata, the two fields the persona sheet reads. Port of
/// the `ChatBackend` shape the host answers `chat.backends` with.
data class PersonaBackend(val id: String, val label: String, val installed: Boolean?)

/// Which face a persona wears in the editor. Zero is fine: it falls back to a
/// settled look derived from the name, or the brief when there is no name yet.
fun faceSeedFor(persona: ChatPersona): ULong =
    if (persona.seed != 0UL) persona.seed
    else personaSeed(persona.name.ifEmpty { persona.systemPrompt })

/// Starting points for a blank brief, from `PersonaEditor`.
val personaStartingPoints: List<Pair<String, String>> = listOf(
    "Reviewer" to "Reviews changes carefully, says what is wrong before what is fine, and never rewrites more than was asked.",
    "Explainer" to "Explains what code does in plain language, with a short example, and checks understanding before moving on.",
    "Refactorer" to "Finds duplication and unclear naming, proposes the smallest change that fixes it, and never mixes a refactor with a behaviour change.",
    "Rubber duck" to "Asks questions rather than answering them, and helps me find the problem myself.",
)

private fun JsonObject.stringOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

private fun JsonObject.boolOrNull(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull

private fun JsonObject.uLongOrNull(key: String): ULong? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    primitive.longOrNull?.let { return it.toULong() }
    return primitive.contentOrNull?.toULongOrNull()
}

/// Total readers for the persona answers: missing stays missing, and a value
/// of the wrong shape reads as absent rather than throwing.
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

/// The personas a folder can use, plus which one new chats inherit. The host
/// answers `chat.personas` with an object carrying both; an older answer that
/// is a bare array reads as the list with no default.
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

/// The agents a draft can be improved with. The shell backend drafts nothing,
/// so it is filtered here and not in the UI.
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

/// Params for `chat.personas` and `chat.personaDefault`: the folder whose
/// voices are being managed.
fun personaScopeParams(workspaceId: String): JsonObject = buildJsonObject { put("workspaceId", workspaceId) }

fun personaDefaultParams(workspaceId: String, personaId: String): JsonObject = buildJsonObject {
    put("workspaceId", workspaceId)
    put("personaId", personaId)
}

/// Params for `chat.personaSave`: the persona plus the folder it is saved
/// from. The persona's own workspace id carries the scope: nil is shared.
fun personaSaveParams(persona: ChatPersona, workspaceId: String?): JsonObject = buildJsonObject {
    put(
        "persona",
        buildJsonObject {
            put("id", persona.id)
            if (persona.workspaceId != null) put("workspaceId", persona.workspaceId) else put("workspaceId", JsonNull)
            put("name", persona.name)
            put("systemPrompt", persona.systemPrompt)
            put("seed", persona.seed.toLong())
        },
    )
    if (workspaceId != null) put("workspaceId", workspaceId)
}

/// Params for `chat.personaDraft`: one short turn on an installed agent. The
/// name travels only when there is one to keep.
fun personaDraftParams(brief: String, backend: String, name: String?): JsonObject = buildJsonObject {
    put("text", brief)
    put("backend", backend)
    if (!name.isNullOrBlank()) put("name", name)
}

fun personaRemoveParams(id: String): JsonObject = buildJsonObject { put("id", id) }
