// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class TeamHistoryWindowTest {
    private fun row(n: Int) = buildJsonObject { put("seq", n); put("text", "row $n") }

    @Test fun earlierPagesKeepTheirOrderAndRefreshReturnsToTheLatestPage() {
        val latest = TeamHistoryWindow(listOf(row(3), row(4)))
        val older = latest.merge(listOf(row(1), row(2)), earlier = true)
        assertEquals(listOf(row(1), row(2), row(3), row(4)), older.events)
        assertEquals(listOf(row(5)), older.merge(listOf(row(5)), earlier = false).events)
    }

    @Test fun theWindowBoundsRowsAndUtf8BytesWithoutAnUnboundedArchive() {
        val bounded = TeamHistoryWindow(listOf(row(3))).merge(listOf(row(1), row(2)), true, rowLimit = 2)
        assertEquals(listOf(row(1), row(2)), bounded.events)
        assertTrue(bounded.truncated)
        assertFalse(bounded.merge(listOf(row(9)), false).truncated)
        val unicode = buildJsonObject { put("text", "🙂".repeat(10)) }
        val bytes = unicode.toString().toByteArray(Charsets.UTF_8).size
        assertTrue(TeamHistoryWindow(emptyList()).merge(listOf(unicode), false, byteLimit = bytes - 1).events.isEmpty())
        assertEquals(listOf(unicode), TeamHistoryWindow(emptyList()).merge(listOf(unicode), false, byteLimit = bytes).events)
    }
}
