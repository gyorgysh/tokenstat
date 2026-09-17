// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// The trial line renders what Play configured, in words, and stays silent
/// when the offer has a single phase.
class BillingPhasesTest {
    @Test
    fun periodsHumanize() {
        assertEquals("3 days", humanizeBillingPeriod("P3D"))
        assertEquals("1 week", humanizeBillingPeriod("P1W"))
        assertEquals("1 month", humanizeBillingPeriod("P1M"))
        assertEquals("1 year", humanizeBillingPeriod("P1Y"))
        assertEquals("P2W3D", humanizeBillingPeriod("P2W3D"))
    }

    @Test
    fun singlePhaseShowsNothing() {
        assertNull(introCaption(listOf(PhaseView("$99.00", "P1Y"))))
        assertNull(introCaption(emptyList()))
    }

    @Test
    fun introPhaseBuildsCaption() {
        assertEquals(
            "Free for 3 days, then $99.00.",
            introCaption(listOf(PhaseView("Free", "P3D"), PhaseView("$99.00", "P1Y"))),
        )
    }

    @Test
    fun periodDecidesTabNotId() {
        // The yearly plan is `annual` on patron and supporter but `yearly`
        // on legend: the id cannot be trusted, the period can.
        assertEquals("year", intervalOfBasePlan("annual", "P1Y"))
        assertEquals("year", intervalOfBasePlan("yearly", "P1Y"))
        assertEquals("month", intervalOfBasePlan("monthly", "P1M"))
        assertEquals("month", intervalOfBasePlan("monthly", "P6M"))
        // A misnamed id loses to a readable period, whichever way round.
        assertEquals("year", intervalOfBasePlan("monthly", "P1Y"))
        assertEquals("month", intervalOfBasePlan("annual", "P1M"))
    }

    @Test
    fun unreadablePeriodFallsBackToKnownIds() {
        assertEquals("month", intervalOfBasePlan("monthly", ""))
        assertEquals("year", intervalOfBasePlan("annual", "P2W3D"))
        assertEquals("year", intervalOfBasePlan(" Yearly ", "nonsense"))
        assertNull(intervalOfBasePlan("launch-promo", ""))
    }

    @Test
    fun weeklyAndDailyPlansBelongToNeitherTab() {
        assertNull(intervalOfBasePlan("monthly", "P1W"))
        assertNull(intervalOfBasePlan("annual", "P3D"))
    }
}
