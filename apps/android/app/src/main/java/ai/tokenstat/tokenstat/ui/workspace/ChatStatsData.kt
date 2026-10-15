// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

internal fun chatMetric(data: JsonObject?, key: String): Double? =
    (data?.get(key) as? JsonPrimitive)?.doubleOrNull?.takeIf { it.isFinite() && it >= 0 }

internal data class ChatContextMetrics(val used: Double?, val window: Double?, val prompt: Map<String, Double?>) {
    fun capacitySegments(): List<Double> {
        val amount = used ?: return emptyList()
        val values = prompt.values.filterNotNull()
        return if (values.isNotEmpty() && prompt.values.none { it == null } && values.sum() == amount) values else listOf(amount)
    }
}

internal fun chatContextMetrics(data: JsonObject?): ChatContextMetrics {
    val prompt = data?.get("contextBreakdown") as? JsonObject
    return ChatContextMetrics(chatMetric(data, "contextUsed"), chatMetric(data, "contextWindow")?.takeIf { it > 0 },
        if (prompt == null) emptyMap() else listOf("input", "cacheRead", "cacheWrite").associateWith { chatMetric(prompt, it) })
}
