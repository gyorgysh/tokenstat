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
}
