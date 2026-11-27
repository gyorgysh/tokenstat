// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

object GeneralFolder {
    const val MIN_PROTOCOL = 56
    const val INCLUDE = "includeGeneral"

    fun isGeneral(folder: JsonObject): Boolean = (folder["general"] as? JsonPrimitive)?.booleanOrNull == true

    fun present(listed: JsonArray, label: String): JsonArray {
        val (general, projects) = listed.partition { (it as? JsonObject)?.let(::isGeneral) == true }
        val named = general.map { JsonObject((it as JsonObject) + ("name" to JsonPrimitive(label))) }
        return JsonArray(named + projects)
    }

    fun projects(folders: List<JsonObject>): List<JsonObject> = folders.filterNot(::isGeneral)
}
