// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.*
import org.junit.Test

class MarkdownTablesTest {
    @Test fun filenamesAndInlineMarkupRemainInTableCells() {
        val table = MarkdownTables.parse(listOf("| File | What it contains |", "| --- | --- |",
            "| `catalog-seed.json` | **Models** and [pricing](https://example.com) |", "", "Next paragraph"), 0)!!
        assertEquals(listOf("File", "What it contains"), table.header)
        assertEquals(listOf("`catalog-seed.json`", "**Models** and [pricing](https://example.com)"), table.rows.single())
        assertEquals(3, table.end)
    }
    @Test fun alignmentEscapedPipesAndUnevenRows() {
        val table = MarkdownTables.parse(listOf("Name | Cost | Status", ":--- | ---: | :---:",
            "A\\|B | 12", "C | 5 | ready | extra"), 0)!!
        assertEquals(listOf(MarkdownTableAlignment.Left, MarkdownTableAlignment.Right, MarkdownTableAlignment.Center), table.alignment)
        assertEquals(listOf("A|B", "12", ""), table.rows[0])
        assertEquals(listOf("C", "5", "ready"), table.rows[1])
    }
    @Test fun ordinaryPipesAndIncompleteStreamingTablesStayProse() {
        assertNull(MarkdownTables.parse(listOf("a | b", "ordinary sentence"), 0))
        assertNull(MarkdownTables.parse(listOf("| a | b |"), 0))
        assertNull(MarkdownTables.parse(listOf("| a | b |", "| --- |"), 0))
    }
}
