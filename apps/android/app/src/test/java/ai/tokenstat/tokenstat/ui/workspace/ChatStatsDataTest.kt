// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class ChatStatsDataTest {
    @Test fun unknownCapacityAndMissingPromptCategoriesRemainUnknown() {
        val metrics = chatContextMetrics(Json.parseToJsonElement("""{"contextUsed":123,"usage":{"input":99999},"contextBreakdown":{"input":100}}""").jsonObject)
        assertEquals(123.0, metrics.used!!, 0.0)
        assertNull(metrics.window)
        assertNull(metrics.prompt["cacheRead"])
        assertEquals(listOf(123.0), metrics.capacitySegments())
        assertNull(chatContextMetrics(null).used)
    }
    @Test fun onlyCompleteMatchingReportedPromptTotalsSegmentContext() {
        val known = chatContextMetrics(Json.parseToJsonElement("""{"contextUsed":150,"contextWindow":1000,"contextBreakdown":{"input":100,"cacheRead":40,"cacheWrite":10}}""").jsonObject)
        assertEquals(listOf(100.0, 40.0, 10.0), known.capacitySegments())
        assertEquals(listOf(200.0), known.copy(used = 200.0).capacitySegments())
        val invalid = chatContextMetrics(Json.parseToJsonElement("""{"contextUsed":-1,"contextWindow":0,"contextBreakdown":{"input":{},"cacheRead":null}}""").jsonObject)
        assertNull(invalid.used)
        assertNull(invalid.window)
        assertNull(invalid.prompt["input"])
    }
}
