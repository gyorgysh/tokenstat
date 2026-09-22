// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertEquals
import org.junit.Test

/// The fact panels must agree with `ClientInsightFacts.panels`: the same
/// three figures in the same order, each with its own house mark.
class InsightFactsTest {
    @Test
    fun panelsCarryValuesAndMarks() {
        val panels = insightFactPanels(
            tokens = 125_844,
            events = 26_900_000_000,
            count = 7,
            countLabel = "Models",
            formatCompact = { compactTokens(it) },
        )
        assertEquals(3, panels.size)
        assertEquals(InsightFactPanel("Tokens", "126k", "mark_insights"), panels[0])
        assertEquals(InsightFactPanel("Events", "26.9B", "mark_activity"), panels[1])
        assertEquals(InsightFactPanel("Models", "7", "mark_examples"), panels[2])
    }

    @Test
    fun countLabelFollowsTheCut() {
        val panels = insightFactPanels(0, 0, 53, "Days", formatCompact = { compactTokens(it) })
        assertEquals("Days", panels[2].label)
        assertEquals("53", panels[2].value)
        assertEquals("mark_examples", panels[2].mark)
    }

    @Test
    fun zeroesStayZeroes() {
        val panels = insightFactPanels(0, 0, 0, "Coding tools", formatCompact = { compactTokens(it) })
        assertEquals("0", panels[0].value)
        assertEquals("0", panels[1].value)
        assertEquals("0", panels[2].value)
    }
}
