// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** Initial reads are bounded; polling only asks for bytes after the last reply. */
internal class ChatHistoryWindow {
    var events: List<JsonObject> = emptyList(); private set
    var loaded = false; private set
    var generation = 0; private set
    var offset = 0L; private set
    var cursor: String? = null; private set
    var tailCursor: String? = null; private set
    var hasEarlier = false; private set

    fun page(answer: JsonObject, replace: Boolean = false) {
        val rows = (answer["events"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
        if (replace || answer["reset"]?.jsonPrimitive?.booleanOrNull == true) {
            generation++
            events = rows
            offset = answer["nextOffset"]?.jsonPrimitive?.longOrNull ?: 0
            tailCursor = answer["tailCursor"]?.jsonPrimitive?.contentOrNull
        } else events = rows + events
        cursor = answer["cursor"]?.jsonPrimitive?.contentOrNull
        hasEarlier = answer["hasEarlier"]?.jsonPrimitive?.booleanOrNull == true && !cursor.isNullOrEmpty()
        loaded = true
    }

    fun tail(answer: JsonObject, expectedGeneration: Int, expectedOffset: Long): Boolean {
        if (expectedGeneration != generation || expectedOffset != offset ||
            answer["reset"]?.jsonPrimitive?.booleanOrNull == true) return false
        val rows = (answer["events"] as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
        if (rows.isNotEmpty()) events = events + rows
        offset = answer["nextOffset"]?.jsonPrimitive?.longOrNull ?: offset
        tailCursor = answer["tailCursor"]?.jsonPrimitive?.contentOrNull
        return true
    }
}
