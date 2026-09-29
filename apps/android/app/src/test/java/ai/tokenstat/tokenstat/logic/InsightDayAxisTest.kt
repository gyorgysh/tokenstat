// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic
import ai.tokenstat.tokenstat.ui.logic.InsightDayAxis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
class InsightDayAxisTest {
    @Test fun missingDaysKeepTheirDistance() {
        assertEquals(3L, InsightDayAxis.position("2026-09-04")!! - InsightDayAxis.position("2026-09-01")!!)
    }
    @Test fun leapDaysAndInvalidDates() {
        assertEquals(2L, InsightDayAxis.position("2024-03-01")!! - InsightDayAxis.position("2024-02-28")!!)
        assertNull(InsightDayAxis.position("2026-02-30"))
        assertNull(InsightDayAxis.position("not a day"))
    }
}
