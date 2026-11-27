// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

object ChatCacheRules {
    const val MINIMUM_TOKENS = 50_000L

    private fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.number(key: String) = (this[key] as? JsonPrimitive)?.longOrNull

    fun cache(chat: JsonObject?): JsonObject? {
        val cache = chat?.get("promptCache") as? JsonObject ?: return null
        if (cache.text("backend") != chat.text("backend")) return null
        return cache.takeIf { (it.number("tokens") ?: 0) >= MINIMUM_TOKENS }
    }

    fun tokens(chat: JsonObject?): Long = cache(chat)?.number("tokens") ?: 0

    fun idle(chat: JsonObject?, nowMs: Long): Long? {
        val cache = cache(chat) ?: return null
        val idle = nowMs - (cache.number("atMs") ?: return null)
        return idle.takeIf { it > (cache.number("ttlMs") ?: 0) }
    }

    fun switching(chat: JsonObject?, next: String, nowMs: Long): Boolean {
        val cache = cache(chat) ?: return false
        val at = cache.number("atMs") ?: return false
        if (nowMs - at > (cache.number("ttlMs") ?: 0)) return false
        return (cache.text("selection") ?: "") != next
    }

    fun cachedModel(chat: JsonObject?): String? =
        cache(chat)?.let { it.text("model")?.takeIf(String::isNotBlank) ?: it.text("selection") }

    fun duration(milliseconds: Long): String {
        val minutes = maxOf(0, milliseconds) / 60_000
        val hours = minutes / 60
        val days = hours / 24
        return when {
            days > 0 -> if (hours % 24 > 0) "${days}d ${hours % 24}h" else "${days}d"
            hours > 0 -> if (minutes % 60 > 0) "${hours}h ${minutes % 60}m" else "${hours}h"
            else -> "${minutes}m"
        }
    }

    fun tokenCount(count: Long): String = when {
        count >= 1_000_000 -> String.format(java.util.Locale.ROOT, "%.1fM", count / 1_000_000.0)
        count >= 1_000 -> String.format(java.util.Locale.ROOT, "%.1fk", count / 1_000.0)
        else -> count.toString()
    }
}
