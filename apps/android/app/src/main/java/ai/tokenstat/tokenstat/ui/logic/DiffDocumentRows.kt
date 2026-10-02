// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/// Flat, bounded pages let the mobile diff compose only visible rows.
internal data class DiffDocumentRow(
    val key: String,
    val kind: Kind,
    val text: String,
    val number: Int? = null,
    val change: String = "context",
    val continuation: Boolean = false,
) {
    enum class Kind { File, Hunk, Line, Binary, Empty, Untracked }
}

internal data class DiffDocumentPage(val rows: List<DiffDocumentRow>, val total: Long)

internal object DiffDocumentRows {
    fun page(
        diffs: List<JsonObject>,
        fileHeaders: Boolean,
        limit: Int,
        maxLineUnits: Int = 1024,
        checkCancellation: () -> Unit = {},
    ): DiffDocumentPage {
        require(maxLineUnits >= 2)
        val rows = ArrayList<DiffDocumentRow>()
        var total = 0L
        fun append(row: () -> DiffDocumentRow) {
            total++
            if (rows.size < limit) rows.add(row())
        }
        diffs.forEachIndexed { fileIndex, diff ->
            checkCancellation()
            val path = diff.string("path")
            val prefix = "$fileIndex:$path"
            if (fileHeaders) append { DiffDocumentRow("$prefix:file", DiffDocumentRow.Kind.File, path) }
            val hunks = diff["hunks"] as? JsonArray ?: JsonArray(emptyList())
            when {
                diff.string("binary") == "true" -> append {
                    DiffDocumentRow("$prefix:note", DiffDocumentRow.Kind.Binary, "")
                }
                hunks.isEmpty() -> append {
                    val kind = if (diff.string("untracked") == "true") DiffDocumentRow.Kind.Untracked else DiffDocumentRow.Kind.Empty
                    DiffDocumentRow("$prefix:note", kind, "")
                }
                else -> hunks.forEachIndexed hunkLoop@ { hunkIndex, element ->
                    checkCancellation()
                    val hunk = element as? JsonObject ?: return@hunkLoop
                    val key = "$prefix:$hunkIndex"
                    append { DiffDocumentRow("$key:header", DiffDocumentRow.Kind.Hunk, hunk.string("header")) }
                    val lines = hunk["lines"] as? JsonArray ?: JsonArray(emptyList())
                    lines.forEachIndexed { lineIndex, lineElement ->
                        checkCancellation()
                        val line = lineElement as? JsonObject
                        val text = line?.string("text").orEmpty()
                        var start = 0
                        var part = 0
                        // Minified lines can exceed Compose's dimension limit.
                        // Continuations retain every character without one huge view.
                        do {
                            checkCancellation()
                            var end = minOf(text.length, start + maxLineUnits)
                            if (end < text.length && text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end--
                            append {
                                val number = listOf("newLine", "new_line", "oldLine", "old_line")
                                    .firstNotNullOfOrNull { (line?.get(it) as? kotlinx.serialization.json.JsonPrimitive)?.intOrNull }
                                DiffDocumentRow("$key:$lineIndex:$part", DiffDocumentRow.Kind.Line,
                                    text.substring(start, end), number, line?.string("kind").orEmpty().lowercase(), part > 0)
                            }
                            start = end
                            part++
                        } while (start < text.length)
                    }
                }
            }
        }
        return DiffDocumentPage(rows, total)
    }

    private fun JsonObject.string(key: String): String =
        (get(key) as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull.orEmpty()
}
