// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

object TerminalViewer {
    val id: String = UUID.randomUUID().toString()
}

internal fun ptyViewerParams(
    id: String,
    build: JsonObjectBuilder.() -> Unit = {},
): JsonObject = buildJsonObject {
    put("id", id)
    put("viewer", TerminalViewer.id)
    build()
}
