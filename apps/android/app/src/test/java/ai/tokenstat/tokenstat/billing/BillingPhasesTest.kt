// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.billing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

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
        assertEquals("year", intervalOfBasePlan("annual", "P1Y"))
        assertEquals("year", intervalOfBasePlan("yearly", "P1Y"))
        assertEquals("month", intervalOfBasePlan("monthly", "P1M"))
        assertEquals("month", intervalOfBasePlan("monthly", "P6M"))
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

    private fun pick(offers: List<OfferView>, trialUsed: Boolean = false) =
        bestOffer(offers, trialUsed) { it }?.offerId

    private val base = OfferView(null, emptyList(), 99_000_000)

    @Test
    fun taggedCheaperOfferWins() {
        assertEquals("cyber26", pick(listOf(base, OfferView("cyber26", listOf("promo"), 49_500_000))))
    }

    @Test
    fun untaggedOfferIsIgnored() {
        assertNull(pick(listOf(base, OfferView("winback", emptyList(), 10_000_000))))
    }

    @Test
    fun cheapestTaggedOfferWins() {
        assertEquals("deep", pick(listOf(
            base,
            OfferView("light", listOf("PROMO"), 80_000_000),
            OfferView("deep", listOf("promo"), 40_000_000),
        )))
    }

    @Test
    fun offerThatCostsMoreKeepsBasePlan() {
        assertNull(pick(listOf(base, OfferView("odd", listOf("promo"), 120_000_000))))
    }

    @Test
    fun usedTrialSkipsFreeOffer() {
        val offers = listOf(base, OfferView("trial", listOf("promo"), 0), OfferView("half", listOf("promo"), 49_500_000))
        assertEquals("trial", pick(offers))
        assertEquals("half", pick(offers, trialUsed = true))
    }

    @Test
    fun noBasePlanMeansNoProduct() {
        assertNull(bestOffer(listOf(OfferView("cyber26", listOf("promo"), 1)), false) { it })
    }

    @Test
    fun captionCountsRepeatedIntroCycles() {
        assertEquals(
            "$4.99 for 3 months, then $9.99.",
            introCaption(listOf(PhaseView("$4.99", "P1M", 3), PhaseView("$9.99", "P1M", 0))),
        )
    }
}
