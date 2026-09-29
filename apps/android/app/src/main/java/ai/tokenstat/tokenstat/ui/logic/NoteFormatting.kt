// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

/** Selection-preserving editing actions; note contents remain portable Markdown. */
internal enum class NoteFormat(val label: String, val prefix: String, val suffix: String = "", val placeholder: String, val lines: Boolean = false) {
    Heading("Heading", "## ", placeholder = "Heading", lines = true),
    Bold("Bold", "**", "**", "text"),
    Italic("Italic", "*", "*", "text"),
    Bullet("Bulleted list", "- ", placeholder = "List item", lines = true),
    Checklist("Checklist", "- [ ] ", placeholder = "To do", lines = true),
    Quote("Quote", "> ", placeholder = "Quote", lines = true),
    Code("Code", "`", "`", "code");

    data class Edit(val text: String, val start: Int, val end: Int)

    fun apply(text: String, anchor: Int, caret: Int): Edit {
        var start = minOf(anchor, caret).coerceIn(0, text.length)
        var end = maxOf(anchor, caret).coerceIn(start, text.length)
        if (lines) {
            start = text.lastIndexOf('\n', start - 1).let { if (start == 0) 0 else it + 1 }
            // A selection ending at the next line's start excludes that line.
            if (end > start && text[end - 1] == '\n') end--
            else end = text.indexOf('\n', end).let { if (it < 0) text.length else it }
        }
        val selected = text.substring(start, end).ifEmpty { placeholder }
        val replacement = if (lines) selected.split('\n').joinToString("\n") { prefix + it } else prefix + selected + suffix
        val result = text.replaceRange(start, end, replacement)
        return Edit(result, start + prefix.length, start + replacement.length - suffix.length)
    }
}
