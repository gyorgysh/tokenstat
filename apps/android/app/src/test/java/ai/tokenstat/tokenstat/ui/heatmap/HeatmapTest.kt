// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.heatmap

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HeatmapTest {
    @Test
    fun shortDateDropsThisYear() {
        val today = LocalDate.of(2026, 9, 16)
        assertEquals("11 August", shortDate("2026-08-11", today))
        assertEquals("11 August 2025", shortDate("2025-08-11", today))
        assertEquals("not a date", shortDate("not a date", today))
    }

    @Test
    fun spokenDateKeepsTheYear() {
        assertEquals("11 August 2026", spokenDate("2026-08-11"))
        assertEquals("2026-13-99", spokenDate("2026-13-99"))
    }

    @Test
    fun freshnessMatchesApplePhrasing() {
        val now = 1_700_000_000_000L
        assertEquals(
            "updated 1 hour ago" to false,
            calendarFreshness(now - 3_600_000, null, now),
        )
        assertEquals(
            "stale, last updated 2 days ago" to true,
            calendarFreshness(now - 2 * 86_400_000, "stale", now),
        )
        assertNull(calendarFreshness(null, null, now))
        assertNull(calendarFreshness(0, null, now))
    }
}
