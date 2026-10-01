// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import ai.tokenstat.tokenstat.ui.localization.L10n

/** Selection-preserving editing actions; note contents remain portable Markdown. */
internal enum class NoteFormat(val label: String, val prefix: String, val suffix: String = "", val placeholder: String, val lines: Boolean = false) {
    Heading(L10n.text("android.noteformatting.heading.b34f17f0"), "## ", placeholder = L10n.text("android.noteformatting.heading.b34f17f0"), lines = true),
    Bold(L10n.text("android.noteformatting.bold.94fee62e"), "**", "**", "text"),
    Italic(L10n.text("android.noteformatting.italic.9bf37cb5"), "*", "*", "text"),
    Bullet(L10n.text("android.noteformatting.bulleted_list.ce51b395"), "- ", placeholder = L10n.text("android.noteformatting.list_item.201333ac"), lines = true),
    Checklist(L10n.text("android.noteformatting.checklist.73460304"), "- [ ] ", placeholder = L10n.text("android.noteformatting.to_do.100ec1bc"), lines = true),
    Quote(L10n.text("android.noteformatting.quote.eb4cdebd"), "> ", placeholder = L10n.text("android.noteformatting.quote.eb4cdebd"), lines = true),
    Code(L10n.text("android.noteformatting.code.340f4630"), "`", "`", "code");

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
