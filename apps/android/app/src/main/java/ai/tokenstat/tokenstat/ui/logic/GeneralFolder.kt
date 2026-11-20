// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/// The host's folder for chats with no repository (protocol 56).
///
/// `workspace.list` returns it only beside `includeGeneral`, which an older
/// host ignores, so the list itself never offers it where the host cannot
/// serve it. Mirrors Apple `WorkspaceFolder.presented`.
object GeneralFolder {
    const val MIN_PROTOCOL = 56
    const val INCLUDE = "includeGeneral"

    fun isGeneral(folder: JsonObject): Boolean = (folder["general"] as? JsonPrimitive)?.booleanOrNull == true

    /// Names the general folder [label] and lists it first.
    fun present(listed: JsonArray, label: String): JsonArray {
        val (general, projects) = listed.partition { (it as? JsonObject)?.let(::isGeneral) == true }
        val named = general.map { JsonObject((it as JsonObject) + ("name" to JsonPrimitive(label))) }
        return JsonArray(named + projects)
    }

    /// The same list without it, for places that only list projects.
    fun projects(folders: List<JsonObject>): List<JsonObject> = folders.filterNot(::isGeneral)
}
