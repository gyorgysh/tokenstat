// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

internal data class MuseToolPresentation(val verb: String, val target: String)

/** Older Muse starts omit input. Recover only explicit facts from their completed result. */
internal fun refineMuseToolPresentation(
    backend: String?,
    verb: String,
    target: String,
    detail: String?,
): MuseToolPresentation {
    if (!backend.equals("muse", ignoreCase = true)) return MuseToolPresentation(verb, target)
    val refinedVerb = when (verb.lowercase(Locale.ROOT)) {
        "read skill", "read_skill" -> "Read"
        "write todos", "write_todos" -> "TodoWrite"
        "bash input", "bash_input" -> "Bash"
        else -> verb
    }
    if (target.isNotEmpty() || detail.isNullOrEmpty() || detail.length > MUSE_RESULT_LIMIT
        || detail.toByteArray(Charsets.UTF_8).size > MUSE_RESULT_LIMIT) {
        return MuseToolPresentation(refinedVerb, target)
    }
    val text = detail.trim()
    val value = if (text.startsWith('{')) runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() else null
    fun field(key: String): String? = (value?.get(key) as? JsonPrimitive)?.takeIf { it.isString }
        ?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
    val firstLine = text.lineSequence().firstOrNull().orEmpty()
    val inferred = when (refinedVerb) {
        "Bash", "Shell" -> field("command") ?: if (text.startsWith('{')) null else text.lineSequence().take(2)
            .firstOrNull { it.startsWith("$ ") }?.removePrefix("$ ")?.trim()?.takeIf { it.isNotEmpty() }
        "Read" -> READ_FILE.matchEntire(firstLine)?.groupValues?.get(1) ?: skillName(firstLine)
        "Write" -> WRITE_FILE.matchEntire(firstLine)?.groupValues?.get(1)
        "WebSearch" -> field("query")
        "TodoWrite" -> {
            val count = (value?.get("items") as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.takeIf { it >= 0 }
            if (count != null) {
                val revision = (value?.get("revision") as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull?.takeIf { it >= 0 }
                "$count ${if (count == 1L) "todo" else "todos"}" + (revision?.let { " (revision $it)" } ?: "")
            } else TODO_SUMMARY.matchEntire(firstLine)?.value
        }
        else -> null
    }
    return MuseToolPresentation(refinedVerb, inferred?.takeIf { it.isNotBlank() }?.let(ChatToolState::clip) ?: target)
}

private const val MUSE_RESULT_LIMIT = 128 * 1024
private val READ_FILE = Regex("Read text file `([^`\\r\\n]+)`\\.")
private val WRITE_FILE = Regex("wrote [0-9]+ bytes to ([^\\r\\n]+)")
private val TODO_SUMMARY = Regex("(?:[0-9]+ todos?|no todos)(?: \\(revision [0-9]+\\))?")
private val SKILL_NAME = Regex("(?:^|\\s)name\\s*=\\s*([\"'])([^\"'\\r\\n]+)\\1(?:\\s|$)")

private fun skillName(line: String): String? {
    if (!line.startsWith("<read-skill-result ") || '>' !in line) return null
    val attributes = line.substringBefore('>').removePrefix("<read-skill-result ").trimEnd().removeSuffix("/").trimEnd()
    return SKILL_NAME.find(attributes)?.groupValues?.get(2)
}
