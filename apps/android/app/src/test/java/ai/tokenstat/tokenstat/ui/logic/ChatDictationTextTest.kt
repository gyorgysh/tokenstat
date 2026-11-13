// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChatDictationTextTest {
    @Test
    fun readingsReplaceEachOtherAfterTheTypedDraft() {
        val text = ChatDictationText("Fix the")
        assertEquals("Fix the bug", text.apply("bug", "Fix the"))
        assertEquals("Fix the bug in parsing", text.apply(" bug in parsing ", "Fix the bug"))
        assertEquals("Fix the bug in parsing", text.expected)
    }

    @Test
    fun anEditByHandStopsDictation() {
        val text = ChatDictationText("")
        assertEquals("hello", text.apply("hello", ""))
        assertNull(text.apply("hello there", "hello!"))
    }

    @Test
    fun joinAddsOneSpaceOnlyWhereNeeded() {
        assertEquals("a b", ChatDictationText.join("a", "b"))
        assertEquals("a\nb", ChatDictationText.join("a\n", "b"))
        assertEquals("b", ChatDictationText.join("", "b"))
        assertEquals("a", ChatDictationText.join("a", ""))
    }

    @Test
    fun finishedStretchesStayAndTheLiveOneIsReplaced() {
        val transcript = ChatDictationTranscript()
        transcript.hear("first")
        transcript.hear("first part")
        transcript.finish("First part.")
        transcript.hear("then")
        assertEquals("First part. then", transcript.text)
        transcript.hear("then more")
        assertEquals("First part. then more", transcript.text)
    }

    @Test
    fun levelsStayInTheBand() {
        assertEquals(0f, dictationLevel(-10f))
        assertEquals(1f, dictationLevel(20f))
        assertEquals(0.5f, dictationLevel(4f))
    }
}
