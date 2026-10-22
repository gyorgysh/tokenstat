// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.*

private fun pageRows(answer: JsonObject, field: String): List<JsonObject> {
    val raw = answer[field] as? JsonArray ?: error("Invalid Team page")
    val rows = raw.map { it as? JsonObject ?: error("Invalid Team row") }
    val ids = rows.map { (it["id"] as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.takeIf { id -> id.isNotEmpty() } ?: error("Invalid Team row") }
    require(ids.distinct().size == ids.size && rows.size <= 100) { "Invalid Team page" }
    return rows
}
internal data class TeamDirectoryPage(val rows: List<JsonObject>, val next: Int?) {
    companion object {
        fun read(answer: JsonObject, field: String, offset: Int): TeamDirectoryPage {
            val value = answer["nextOffset"]
            val next = if (value == null || value == JsonNull) null else (value as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: error("Invalid Team page")
            require(next == null || next > offset && next <= 10000) { "Invalid Team page" }
            return TeamDirectoryPage(pageRows(answer, field), next)
        }
    }
}
internal data class TeamCatalogPage(val rows: List<JsonObject>, val next: String?) {
    companion object {
        fun read(answer: JsonObject, checkout: String, cursor: String?): TeamCatalogPage {
            val value = answer["nextCursor"]
            val next = if (value == null || value == JsonNull) null else (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: error("Invalid Team page")
            require(next == null || next.isNotEmpty() && next != cursor) { "Invalid Team page" }
            val rows = pageRows(answer, "shares")
            require(rows.all { (it["checkoutId"] as? JsonPrimitive)?.content == checkout }) { "Invalid Team checkout" }
            return TeamCatalogPage(rows, next)
        }
        fun append(before: List<JsonObject>, incoming: List<JsonObject>): List<JsonObject> = (before + incoming).distinctBy { it["id"] }
    }
}
