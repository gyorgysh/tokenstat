// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import org.junit.Assert.*
import org.junit.Test

class ChartFenceTest {
    private val json = """{"version":1,"type":"bar","title":"Chart","categories":["A"],"series":[{"name":"Count","data":[1]}]}"""
    private fun codes(text: String) = parseMarkdown(text).filterIsInstance<MdBlock.Code>()

    @Test fun streamingNeverPresentsPartialDataAsACompleteChart() {
        val source = "```tokenstat-chart\n$json"
        for (end in source.indices) assertTrue(codes(source.take(end)).none { it.chart && !it.pending })
        assertTrue(codes(source).single().pending)
        val complete = codes("$source\n```").single()
        assertTrue(complete.chart)
        assertFalse(complete.pending)
        assertEquals(json, complete.code.trimEnd())
    }

    @Test fun fencesMatchTheirOpeningDelimiterAndKeepOrdinaryCode() {
        assertTrue(codes("~~~tokenstat-chart\n$json\n~~~").single().chart)
        assertTrue(codes("````tokenstat-chart\n$json\n```\n").single().pending)
        assertFalse(codes("```json\n$json\n```").single().chart)
        assertTrue(codes("```tokenstat-chart\n$json\n~~~").single().pending)
        assertEquals(2, codes("```tokenstat-chart\n$json\n```\n\nAfter\n\n```tokenstat-chart\n$json\n```").size)
    }

    @Test fun excessChartsKeepAllDataWithoutMountingMoreBrowsers() {
        val complete = "```tokenstat-chart\n$json\n```"
        val blocks = codes(List(200) { complete }.joinToString("\n\n"))
        assertEquals(200, blocks.size)
        assertEquals(4, blocks.count { it.chart })
        assertTrue(blocks.all { it.code.trimEnd() == json })
        assertTrue(blocks.drop(4).none { it.chart || it.pending })
        val unfinished = codes(List(4) { complete }.joinToString("\n\n") + "\n\n```tokenstat-chart\n$json").last()
        assertFalse(unfinished.chart)
        assertFalse(unfinished.pending)
        assertEquals(json, unfinished.code.trimEnd())
    }
}
