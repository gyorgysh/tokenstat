// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertEquals
import org.junit.Test

/// The spend window must agree with `DeviceHistory`: the same depth per
/// tier, the same phrases, and the same detail line under the figure.
class DeviceHistoryTest {
    @Test
    fun daysFollowTheTier() {
        assertEquals(3650, deviceHistoryDays("legend"))
        assertEquals(3650, deviceHistoryDays("Patron"))
        assertEquals(365, deviceHistoryDays("supporter"))
        assertEquals(30, deviceHistoryDays("free"))
        assertEquals(30, deviceHistoryDays(null))
        assertEquals(30, deviceHistoryDays("team"))
    }

    @Test
    fun windowPhrasesMatch() {
        assertEquals("all time", deviceWindowPhrase(3650))
        assertEquals("the last year", deviceWindowPhrase(365))
        assertEquals("the last day", deviceWindowPhrase(1))
        assertEquals("the last 30 days", deviceWindowPhrase(30))
    }

    @Test
    fun spendDetailListsDaysEventsAndShare() {
        val usage = DeviceUsage(valueMicros = 500_000, events = 42, activeDays = 3, days = 30)
        assertEquals(
            "3 active days, 42 events, 50% of the account",
            deviceSpendDetail(usage, accountTotalMicros = 1_000_000),
        )
    }

    @Test
    fun spendDetailSingularDayAndUnknownTotal() {
        val usage = DeviceUsage(valueMicros = 250_000, events = 7, activeDays = 1, days = 30)
        assertEquals(
            "1 active day, 7 events",
            deviceSpendDetail(usage, accountTotalMicros = 0),
        )
    }
}
