// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.JsonObject

internal data class TeamHistoryWindow(val events: List<JsonObject>, val truncated: Boolean = false) {
    fun merge(incoming: List<JsonObject>, earlier: Boolean, byteLimit: Int = 8 * 1024 * 1024, rowLimit: Int = 2000): TeamHistoryWindow {
        val combined = if (earlier) incoming + events else incoming
        val kept = mutableListOf<JsonObject>()
        var bytes = 0
        for (event in combined) {
            bytes += event.toString().toByteArray(Charsets.UTF_8).size
            if (kept.size == rowLimit || bytes > byteLimit) break
            kept += event
        }
        return TeamHistoryWindow(kept, (earlier && truncated) || kept.size < combined.size)
    }
}
