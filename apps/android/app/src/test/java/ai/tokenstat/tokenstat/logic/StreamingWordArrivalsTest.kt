// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.workspace.StreamingWordArrivals
import org.junit.Assert.*
import org.junit.Test

class StreamingWordArrivalsTest {
    @Test fun appendedWordsDoNotRestartEarlierFades() {
        val state = StreamingWordArrivals()
        assertTrue(state.update("Already here", 0).all { it.born == null })
        assertEquals(listOf(null, null, 1000L), state.update("Already here new", 1000).map { it.born })
        assertEquals(listOf(null, null, 1000L, 1100L), state.update("Already here newer word", 1100).map { it.born })
        assertTrue(state.update("Already here newer word", 2000).all { it.born == null })
    }
    @Test fun replacedAndReopenedTextNeverReplays() {
        val state = StreamingWordArrivals()
        state.update("old", 0)
        assertTrue(state.update("Restored history contains more words", 100).all { it.born == null })
        assertTrue(state.update("Restored", 110).all { it.born == null })
        assertTrue(state.update("Restored history contains more words", 120).all { it.born == null })
        assertEquals(130L, state.update("Restored history contains more words next", 130).last().born)
        assertTrue(StreamingWordArrivals().update("Restored", 120).all { it.born == null })
    }
    @Test fun unicodeRangesUseTextLayoutOffsetsWithoutChangingText() {
        val state = StreamingWordArrivals()
        state.update("Hello", 0)
        val text = "Hello 🌍\n日本語"
        val words = state.update(text, 100)
        assertEquals(listOf("Hello", "🌍", "日本語"), words.map { text.substring(it.start, it.end) })
        assertEquals(listOf(null, 100L, 100L), words.map { it.born })
    }
}
