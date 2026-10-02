// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.NoteList
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Full-body edits must replace the version the editor actually reviewed. */
internal suspend fun editNote(
    baseline: NoteList.NoteCard,
    title: String,
    body: String,
    request: suspend (String, JsonObject) -> JsonObject,
): JsonObject {
    val revision = requireNotNull(baseline.revision) { "A note edit needs its saved revision" }
    return request("todo.edit", buildJsonObject {
        put("id", baseline.id)
        put("expectedRevision", revision)
        put("title", title)
        put("notes", body)
    })
}
