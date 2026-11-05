// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.math.BigInteger
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatUsageTotalsTest {
    private fun json(s: String) = Json.parseToJsonElement(s).jsonObject
    private val totals = """{"input":9007199254740993,"output":20,"cacheRead":80,"cacheWrite":4,"cost":1.25}"""
    private fun page(usage: String = totals) = json("""{"events":[],"usage":$usage,"nextOffset":100,"hasEarlier":true,"cursor":"older"}""")

    @Test fun countsStayExactAndOlderPagesDoNotChangeTheTotal() {
        val history = ChatHistoryWindow()
        history.page(page(), true)
        assertEquals(BigInteger("9007199254740993"), history.usage!!.input)
        val original = history.usage
        history.page(json("""{"events":[{"event":{"kind":"usage","input":100}}],"hasEarlier":false}"""))
        assertEquals(original, history.usage)
        val tail = json("""{"events":[{"event":{"kind":"usage","input":2,"output":3,"cache_read":4,"cache_write":5,"cost_usd":0.5}}],"nextOffset":200}""")
        assertTrue(history.tail(tail, history.generation, 100))
        assertEquals(BigInteger("9007199254740995"), history.usage!!.input)
        assertEquals(BigInteger("84"), history.usage!!.cacheRead)
        assertEquals(1.75, history.usage!!.cost, 0.0)
        assertFalse(history.tail(tail, history.generation, 100))
        assertEquals(1.75, history.usage!!.cost, 0.0)
    }

    @Test fun resetReplacesUsageAndOldHostsWithoutTotalsRemainUnknown() {
        val history = ChatHistoryWindow(); history.page(page(), true)
        val generation = history.generation
        history.page(json("""{"reset":true,"events":[],"nextOffset":0}"""))
        assertNull(history.usage)
        assertFalse(history.tail(json("""{"events":[],"nextOffset":200}"""), generation, 100))
        assertNull(history.usage)
        history.page(page(), true)
        assertNotNull(history.usage)
    }

    @Test fun malformedAndOverflowingCountersNeverBecomePartialOrZeroTotals() {
        for (bad in listOf("null", "{}", totals.replace("20", "-1"), totals.replace("20", "1.5"),
            totals.replace("20", "\"20\""), totals.replace("1.25", "1e309"), totals.replace("1.25", "-0.5"))) {
            assertNull(ChatUsageTotals.decode(Json.parseToJsonElement(bad) as? JsonObject))
        }
        val maximum = ChatUsageTotals.decode(json(totals.replace("9007199254740993", "18446744073709551615")))!!
        assertNull(maximum.tail(listOf(json("""{"event":{"kind":"usage","input":1}}"""))))
        assertNull(maximum.tail(listOf(json("""{"event":{"kind":"usage","output":{}}}"""))))
        assertEquals(maximum, maximum.tail(listOf(json("""{"event":{"kind":"toolCall","input":{}}}"""))))
        assertNull(maximum.tail(listOf(json("""{"kind":"retainedUsage","usage":$totals}"""))))
        assertNull(maximum.tail(listOf(json("""{"kind":"teamAgentSegment","usage":$totals}"""))))
    }
}
