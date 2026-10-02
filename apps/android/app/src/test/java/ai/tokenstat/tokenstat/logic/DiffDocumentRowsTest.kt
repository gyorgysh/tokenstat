// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.DiffDocumentRow
import ai.tokenstat.tokenstat.ui.logic.DiffDocumentRows
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CancellationException

class DiffDocumentRowsTest {
    private fun file(hunks: List<JsonObject> = emptyList(), binary: Boolean = false) = buildJsonObject {
        put("path", "same.swift"); put("binary", binary); put("hunks", JsonArray(hunks))
    }
    private fun hunk(lines: Int) = buildJsonObject {
        put("header", "@@ same header @@")
        put("lines", JsonArray(List(lines) { index -> buildJsonObject {
            put("text", "line $index"); put("kind", "added"); put("new_line", index + 1)
        } }))
    }

    @Test fun expansionPreservesKeysAndBoundsEveryDisplayRow() {
        val diffs = listOf(file(listOf(hunk(4000), hunk(4))), file(listOf(hunk(3))))
        val first = DiffDocumentRows.page(diffs, true, 2000)
        val expanded = DiffDocumentRows.page(diffs, true, 4000)
        assertEquals(4012L, first.total)
        assertEquals(2000, first.rows.size)
        assertEquals(first.rows, expanded.rows.take(2000))
        assertEquals(expanded.rows.size, expanded.rows.map { it.key }.toSet().size)
        val all = DiffDocumentRows.page(diffs, true, 5000)
        assertEquals(all.rows.size, all.rows.map { it.key }.toSet().size)
        assertEquals(1, all.rows.first { it.kind == DiffDocumentRow.Kind.Line }.number)
    }

    @Test fun binaryAndEmptyHunksCannotBypassTheBudget() {
        val binary = DiffDocumentRows.page(List(100000) { file(binary = true) }, true, 2000)
        assertEquals(200000L, binary.total)
        assertEquals(2000, binary.rows.size)
        val empty = DiffDocumentRows.page(listOf(file(List(100000) { hunk(0) })), false, 2000)
        assertEquals(100000L, empty.total)
        assertEquals(2000, empty.rows.size)
    }

    @Test fun canceledPreparationStopsBeforeTraversingTheRest() {
        var checks = 0
        try {
            DiffDocumentRows.page(List(100) { file() }, true, 2000) {
                if (++checks == 5) throw CancellationException()
            }
            throw AssertionError("Canceled page completed")
        } catch (_: CancellationException) {
            assertEquals(5, checks)
        }
    }

    @Test fun zeroBudgetCountsWithoutRetainingAnyRows() {
        val page = DiffDocumentRows.page(listOf(file(listOf(hunk(400000)))), false, 0)
        assertTrue(page.rows.isEmpty())
        assertEquals(400001L, page.total)
    }

    @Test fun minifiedLinesRemainCompleteAcrossBoundedUnicodeContinuations() {
        val text = "x" + "🙂".repeat(10000)
        val hunk = buildJsonObject {
            put("header", "@@ long line @@")
            put("lines", JsonArray(listOf(buildJsonObject { put("text", text); put("newLine", 7) })))
        }
        val page = DiffDocumentRows.page(listOf(file(listOf(hunk))), false, 10000, maxLineUnits = 80)
        val lines = page.rows.filter { it.kind == DiffDocumentRow.Kind.Line }
        assertEquals(text, lines.joinToString("") { it.text })
        assertTrue(lines.all { it.text.length <= 80 && !it.text.last().isHighSurrogate() })
        assertTrue(lines.drop(1).all { it.continuation && it.number == 7 })
        assertEquals(page.rows.size.toLong(), page.total)
        val first = DiffDocumentRows.page(listOf(file(listOf(hunk))), false, 10, maxLineUnits = 80)
        assertEquals(page.rows.take(10), first.rows)
        assertEquals(page.total, first.total)
    }
}
