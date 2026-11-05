// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.harnessCanonicalID
import kotlinx.serialization.json.*

internal fun chatQuotaPercent(window: JsonObject): Double? =
    (window["percent"] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull?.takeIf { it.isFinite() && it >= 0 }

internal fun chatQuotaReading(readings: JsonArray, backend: String, failed: Boolean = false): JsonObject? {
    val provider = readings.filterIsInstance<JsonObject>().firstOrNull {
        harnessCanonicalID(it.str("source").orEmpty()) == harnessCanonicalID(backend)
    } ?: return null
    val windows = (provider["windows"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().filter {
        !it.str("label").isNullOrBlank() && chatQuotaPercent(it) != null
    }
    if (windows.isEmpty()) return null
    return JsonObject(provider + ("windows" to JsonArray(windows)) +
        ("stale" to JsonPrimitive(failed || provider.bol("stale"))))
}

private val quotaLabelSpace = Regex("\\s+")

internal fun chatQuotaTag(label: String): String? {
    val normalized = label.trim().lowercase().replace("·", " · ").replace('-', ' ').replace(quotaLabelSpace, " ")
    return when {
        normalized in listOf("5 hour", "5h") || normalized.endsWith("· 5 hour") || normalized.endsWith("· 5h") -> "5h"
        normalized in listOf("weekly", "7d", "7 day") || normalized.endsWith("· weekly") || normalized.contains("per week") -> "7d"
        normalized in listOf("monthly", "30d") || normalized.endsWith("· monthly") || normalized.contains("per month") -> "30d"
        else -> null
    }
}

internal fun chatQuotaMainWindow(reading: JsonObject): JsonObject? {
    val windows = (reading["windows"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
        .filter { chatQuotaPercent(it) != null }
    val general = if (harnessCanonicalID(reading.str("source").orEmpty()) == "codex") windows.filter {
        it.str("scope").equals("general", ignoreCase = true) && chatQuotaTag(it.str("label").orEmpty()) != null
    } else emptyList()
    val preferred = general.ifEmpty { windows }
    return preferred.firstOrNull { chatQuotaTag(it.str("label").orEmpty()) == "5h" }
        ?: preferred.firstOrNull { chatQuotaTag(it.str("label").orEmpty()) == "7d" }
        ?: preferred.firstOrNull()
}
