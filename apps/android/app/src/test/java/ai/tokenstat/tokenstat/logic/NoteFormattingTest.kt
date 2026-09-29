// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.NoteFormat
import org.junit.Assert.assertEquals
import org.junit.Test

class NoteFormattingTest {
    @Test fun wrapsSelectionAndRetainsUnicode() {
        val edit = NoteFormat.Bold.apply("A 🐈 sleeps", 4, 2)
        assertEquals("A **🐈** sleeps", edit.text)
        assertEquals("🐈", edit.text.substring(edit.start, edit.end))
    }
    @Test fun checklistCoversWholeSelectedLines() {
        val edit = NoteFormat.Checklist.apply("first\nsecond\nthird", 2, 13)
        assertEquals("- [ ] first\n- [ ] second\nthird", edit.text)
    }
    @Test fun caretFormatsOnlyItsParagraph() {
        assertEquals("one\n> two\nthree", NoteFormat.Quote.apply("one\ntwo\nthree", 5, 5).text)
    }
    @Test fun emptyInsertionSelectsPlaceholder() {
        val edit = NoteFormat.Bold.apply("", 0, 0)
        assertEquals("**text**", edit.text)
        assertEquals("text", edit.text.substring(edit.start, edit.end))
    }
    @Test fun emptyFinalLineStaysSeparate() {
        assertEquals("one\n- List item", NoteFormat.Bullet.apply("one\n", 4, 4).text)
    }
}
