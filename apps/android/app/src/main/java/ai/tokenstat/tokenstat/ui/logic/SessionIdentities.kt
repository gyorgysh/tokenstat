// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.*

enum class SessionIdentityStatus { Current, Saved, Historical }

data class SessionIdentity(val backend: String, val id: String, val status: SessionIdentityStatus,
    val sourceConversationId: String? = null, val firstSeenAtMs: Long? = null, val lastSeenAtMs: Long? = null)

data class SessionIdentities(val entries: List<SessionIdentity> = emptyList(), val total: Int = 0, val truncated: Boolean = false,
    val sourceConversationIds: List<String> = emptyList())

/** Only the host's explicit identity projection is readable. Legacy resume
 * tokens, nested meters, archive paths and arbitrary resume objects are not IDs. */
fun parseChatSessionIdentities(inspection: JsonObject?): SessionIdentities = parseSessionIdentities(inspection?.get("sessions"))
fun parseTerminalSessionIdentities(info: JsonObject?): SessionIdentities = parseSessionIdentities(info?.get("sessionIdentities"))

private val nativeSessionUuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
private val openCodeSessionId = Regex("ses_[0-9a-fA-F]{12}[0-9a-zA-Z]{14}")

private fun validNativeSessionId(backend: String, id: String): Boolean = when (backend) {
    "claude", "codex", "cursor", "muse", "grok", "agy" ->
        nativeSessionUuid.matches(id) && id != "00000000-0000-0000-0000-000000000000"
    "opencode", "opencode2" -> openCodeSessionId.matches(id)
    else -> false
}

private fun parseSessionIdentities(value: JsonElement?): SessionIdentities {
    val objectValue = value as? JsonObject ?: return SessionIdentities()
    val rows = objectValue["entries"] as? JsonArray ?: return SessionIdentities()
    fun text(objectValue: JsonObject, key: String): String? = (objectValue[key] as? JsonPrimitive)
        ?.takeIf { it.isString }?.contentOrNull
    fun id(value: String?): String? = value?.takeIf {
        it.isNotEmpty() && it.length <= 512 && it.none { char -> char.isWhitespace() || char.isISOControl() } &&
            it.none { char -> char == '/' || char == '\\' || char == '{' || char == '[' }
    }
    val validEntries = rows.take(256).mapNotNull { element ->
        val row = element as? JsonObject ?: return@mapNotNull null
        val backend = text(row, "backend")?.takeIf { name ->
            name.isNotEmpty() && name.length <= 64 && name.all { it.isLetterOrDigit() || it == '_' || it == '-' }
        } ?: return@mapNotNull null
        val sessionId = text(row, "id")?.takeIf { validNativeSessionId(backend, it) } ?: return@mapNotNull null
        val status = when (text(row, "status")) {
            "current" -> SessionIdentityStatus.Current
            "saved" -> SessionIdentityStatus.Saved
            // A newer host may add lifecycle states. They remain lookup-only
            // historical references until this client understands the state.
            else -> SessionIdentityStatus.Historical
        }
        SessionIdentity(backend, sessionId, status, id(text(row, "sourceConversationId")),
            (row["firstSeenAtMs"] as? JsonPrimitive)?.longOrNull?.takeIf { it >= 0 },
            (row["lastSeenAtMs"] as? JsonPrimitive)?.longOrNull?.takeIf { it >= 0 })
    }
    val entries = validEntries.sortedWith(compareBy<SessionIdentity> { it.status.ordinal }.thenByDescending { it.lastSeenAtMs ?: 0 })
        .distinctBy { it.backend to it.id }
    // Keep every visible source even when repeated native IDs are merged.
    val sourceConversationIds = validEntries.mapNotNull { it.sourceConversationId }.distinct().take(64)
    val total = ((objectValue["total"] as? JsonPrimitive)?.intOrNull ?: entries.size).coerceAtLeast(entries.size)
    return SessionIdentities(entries.take(64), total,
        (objectValue["truncated"] as? JsonPrimitive)?.booleanOrNull == true || rows.size > 256 || entries.size > 64 || total > entries.size,
        sourceConversationIds)
}
