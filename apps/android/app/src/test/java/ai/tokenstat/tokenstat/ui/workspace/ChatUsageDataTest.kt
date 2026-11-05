// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatUsageDataTest {
    private fun provider(source: String, windows: String) = Json.parseToJsonElement("""{"source":"$source","windows":$windows}""").jsonObject
    @Test fun zeroFiveHourUsageTakesPriorityAndUnknownBackendsNeverBorrowReadings() {
        val p = provider("claude_code", """[{"label":"weekly","percent":99},{"label":"5-hour","percent":0}]""")
        val reading = chatQuotaReading(JsonArray(listOf(p)), "claude")!!
        assertEquals(0.0, chatQuotaPercent(chatQuotaMainWindow(reading)!!)!!, 0.0)
        assertNull(chatQuotaReading(JsonArray(listOf(p)), "muse"))
        assertTrue(chatQuotaReading(JsonArray(listOf(p)), "claude", failed = true)!!.bol("stale"))
    }
    @Test fun weeklyAndNamedWindowsAreAvailableWithoutInventingZeroForInvalidData() {
        val p = provider("cursor", """[{"label":"5-hour","percent":null},{"label":"weekly","percent":2},{"label":"billing cycle","percent":9}]""")
        assertEquals("weekly", chatQuotaMainWindow(chatQuotaReading(JsonArray(listOf(p)), "cursor")!!)!!.str("label"))
        val named = provider("cursor", """[{"label":"billing cycle","percent":9}]""")
        assertEquals("billing cycle", chatQuotaMainWindow(named)!!.str("label"))
        for (bad in listOf("null", "-1", "1e309", "\"0\"", "{}")) {
            assertNull(chatQuotaReading(JsonArray(listOf(provider("cursor", """[{"label":"5-hour","percent":$bad}]"""))), "cursor"))
        }
    }
    @Test fun codexAccountQuotaWinsOverSecondaryModelQuota() {
        val reading = provider("codex", """[{"label":"5-hour","percent":3,"scope":"current model"},{"label":"weekly","percent":99,"scope":"general"}]""")
        assertEquals("general", chatQuotaMainWindow(reading)!!.str("scope"))
        assertEquals("5h", chatQuotaTag("Gemini models · 5-hour"))
        assertEquals("5h", chatQuotaTag(" 5 HOUR "))
        assertEquals("7d", chatQuotaTag("requests per week"))
        assertNull(chatQuotaTag("billing cycle"))
    }
}
