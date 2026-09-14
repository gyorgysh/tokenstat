// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.editor

import ai.tokenstat.tokenstat.ui.theme.SyntaxKind
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

internal fun JsonObject.optStr(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

internal fun JsonObject.optInt(key: String): Int? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.intOrNull

/// One coloured run. `start` and `length` are UTF-16 code units, the same
/// units this client's strings index by, so they drop straight into ranges
/// with no conversion. Port of `SyntaxSpan`.
data class SyntaxSpan(val start: Int, val length: Int, val kind: SyntaxKind) {
    companion object {
        fun parse(obj: JsonObject): SyntaxSpan = SyntaxSpan(
            start = obj.optInt("start") ?: 0,
            length = obj.optInt("len") ?: 0,
            kind = syntaxKindOf(obj.optStr("kind")),
        )

        /// A kind this build does not know decodes as Unknown and renders
        /// as plain text, rather than refusing the whole file.
        fun syntaxKindOf(raw: String?): SyntaxKind = when (raw?.lowercase()) {
            "keyword" -> SyntaxKind.Keyword
            "string" -> SyntaxKind.String
            "number" -> SyntaxKind.Number
            "comment" -> SyntaxKind.Comment
            "type" -> SyntaxKind.Type
            "function" -> SyntaxKind.Function
            "constant" -> SyntaxKind.Constant
            "attribute" -> SyntaxKind.Attribute
            "property" -> SyntaxKind.Property
            "variable" -> SyntaxKind.Variable
            "operator" -> SyntaxKind.Operator
            "punctuation" -> SyntaxKind.Punctuation
            "markup" -> SyntaxKind.Markup
            else -> SyntaxKind.Unknown
        }
    }

    /// Clamp to the buffer so a stale answer cannot paint past the end.
    fun clamped(textLength: Int): SyntaxSpan? {
        val from = start.coerceIn(0, textLength)
        val to = (start + length).coerceIn(0, textLength)
        if (to <= from) return null
        return copy(start = from, length = to - from)
    }
}

/// How a language is commented and indented. Port of `SyntaxRules`.
data class SyntaxRules(
    val lineComment: String? = null,
    val blockComment: List<String> = emptyList(),
    val indent: Int = 4,
) {
    /// What pressing Tab inserts.
    val indentUnit: String get() = " ".repeat(maxOf(1, indent))

    companion object {
        val FALLBACK = SyntaxRules()

        fun parse(obj: JsonObject?): SyntaxRules {
            if (obj == null) return FALLBACK
            return SyntaxRules(
                lineComment = obj.optStr("lineComment"),
                blockComment = (obj["blockComment"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList(),
                indent = obj.optInt("indent") ?: 4,
            )
        }
    }
}

/// The answer to a highlight request. A file with no grammar and a file
/// over the size limit both come back successful with empty spans and a
/// note. Neither is an error. Port of `Highlighting`.
data class Highlighting(
    val language: String? = null,
    val rules: SyntaxRules = SyntaxRules.FALLBACK,
    val spans: List<SyntaxSpan> = emptyList(),
    val note: String? = null,
) {
    companion object {
        fun parse(obj: JsonObject): Highlighting = Highlighting(
            language = obj.optStr("language"),
            rules = SyntaxRules.parse(obj["syntax"] as? JsonObject),
            spans = ((obj["spans"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()).map(SyntaxSpan::parse),
            note = obj.optStr("note"),
        )
    }
}

/// Lines with changes against HEAD, one-based, for the gutter marks.
/// Added lines only: a removed line has no number on the new side, so
/// there is no row in the buffer to mark. Port of
/// `EditorDocument.applyDiff`.
fun changedLinesFromDiff(diff: JsonObject?): Set<Int> {
    if (diff == null) return emptySet()
    val lines = mutableSetOf<Int>()
    val hunks = (diff["hunks"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
    hunks.forEach { hunk ->
        val rows = (hunk["lines"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
        rows.forEach { line ->
            if ((line["kind"]?.jsonPrimitive?.contentOrNull) == "added") {
                line["newLine"]?.jsonPrimitive?.intOrNull?.let { lines.add(it) }
            }
        }
    }
    return lines
}

/// One-based number of the first line where two texts differ, or null
/// when they match. Port of `EditorDocument.firstDifference`.
fun firstDifference(mine: String, other: String): Int? {
    if (mine == other) return null
    val mineLines = mine.split('\n')
    val otherLines = other.split('\n')
    mineLines.zip(otherLines).forEachIndexed { index, (a, b) ->
        if (a != b) return index + 1
    }
    return minOf(mineLines.size, otherLines.size) + 1
}

/// Line math for the gutter. Everything is in UTF-16 units, the same
/// units this client's strings index by. Wrapped lines share their
/// paragraph's number: only paragraph starts are numbered.
/// Port of `EditorGutterMap`.
object EditorGutterMap {
    /// UTF-16 offsets where each one-based line starts. Always starts with 0.
    fun lineStarts(text: String): List<Int> {
        val starts = mutableListOf(0)
        text.forEachIndexed { index, char ->
            if (char == '\n') starts.add(index + 1)
        }
        return starts
    }

    /// One-based paragraph number for a UTF-16 character index.
    fun paragraph(index: Int, starts: List<Int>): Int {
        var line = 1
        var low = 0
        var high = starts.size - 1
        while (low <= high) {
            val mid = (low + high) / 2
            if (starts[mid] <= index) {
                line = mid + 1
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return line
    }
}

/// Find and replace for one open file: literal, case-insensitive matches
/// over the buffer, wrapping in both directions. Port of
/// `EditorFindSession`. Deliberately UI-thread-free so tests exercise it
/// without a view.
class EditorFind {
    companion object {
        /// Bounded so a pathological query cannot mint unbounded ranges.
        const val MATCH_LIMIT = 2000
    }

    var showing: Boolean = false
    var query: String = ""
    var replaceText: String = ""
    var replacing: Boolean = false

    private var matches: List<IntRange> = emptyList()
    private var currentIndex: Int = 0
    private var truncated: Boolean = false
    private var lastText: String = ""

    val hasQuery: Boolean get() = query.isNotEmpty()

    val current: IntRange? get() =
        if (hasQuery && matches.isNotEmpty()) matches[currentIndex % matches.size] else null

    val matchCount: Int get() = matches.size

    fun snapshot(): List<IntRange> = matches.toList()

    val countLabel: String? get() {
        if (!hasQuery) return null
        if (matches.isEmpty()) return "No results"
        val position = (currentIndex % matches.size) + 1
        if (truncated) return "$position of ${matches.size}+"
        return "$position of ${matches.size}"
    }

    val canNavigate: Boolean get() = hasQuery && matches.size > 1
    val canReplace: Boolean get() = hasQuery && matches.isNotEmpty()

    /// Recompute matches against the buffer. Keeps the current position
    /// when the same match is still there, otherwise clamps.
    fun refresh(text: String) {
        lastText = text
        val previous = current
        val (found, cut) = search(query, text)
        matches = found
        truncated = cut
        currentIndex = if (previous != null) {
            matches.indexOf(previous).takeIf { it >= 0 } ?: 0
        } else {
            0
        }
    }

    fun clear() {
        matches = emptyList()
        currentIndex = 0
        truncated = false
    }

    fun goNext() {
        if (!canNavigate) return
        currentIndex = (currentIndex + 1) % matches.size
    }

    fun goPrevious() {
        if (!canNavigate) return
        currentIndex = (currentIndex + matches.size - 1) % matches.size
    }

    /// Replace the current match. Returns the new buffer, or null when
    /// there is nothing to replace.
    fun replaceCurrent(text: String): String? {
        if (!canReplace) return null
        val range = current ?: return null
        return text.substring(0, range.first) + replaceText + text.substring(range.last + 1)
    }

    /// Replace every match. One undo, in this file only.
    fun replaceAll(text: String): String? {
        if (!canReplace) return null
        if (replaceText.isEmpty()) {
            var out = text
            matches.sortedByDescending { it.first }.forEach { range ->
                out = out.substring(0, range.first) + out.substring(range.last + 1)
            }
            return out
        }
        val builder = StringBuilder()
        var cursor = 0
        matches.sortedBy { it.first }.forEach { range ->
            builder.append(text, cursor, range.first)
            builder.append(replaceText)
            cursor = range.last + 1
        }
        builder.append(text, cursor, text.length)
        return builder.toString()
    }

    private fun search(query: String, text: String): Pair<List<IntRange>, Boolean> {
        if (query.isEmpty() || text.isEmpty()) return emptyList<IntRange>() to false
        val out = mutableListOf<IntRange>()
        var truncated = false
        var from = 0
        while (from < text.length) {
            val found = text.indexOf(query, from, ignoreCase = true)
            if (found < 0) break
            // Empty query is excluded above; guard the advance anyway.
            val length = maxOf(query.length, 1)
            out.add(found until found + query.length)
            if (out.size >= MATCH_LIMIT) {
                truncated = true
                break
            }
            val next = found + length
            if (next >= text.length) break
            from = next
        }
        return out to truncated
    }
}
