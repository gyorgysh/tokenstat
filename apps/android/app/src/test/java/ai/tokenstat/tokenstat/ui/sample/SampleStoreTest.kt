// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.sample

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// The sample is a fixed fixture: one exchange, one changed line, invented
/// readings, and the disclaimer that says so. If the copy drifts from
/// `ClientSampleStore`, the two clients tell different stories.
class SampleStoreTest {
    @Test
    fun conversationEndsInOneEdit() {
        assertEquals(3, SampleStore.conversation.size)
        assertEquals(SampleStore.Speaker.PERSON, SampleStore.conversation.first().speaker)
        assertTrue(SampleStore.conversation.last().text.contains("index.html"))
    }

    @Test
    fun diffChangesOneLine() {
        assertEquals("index.html", SampleStore.file)
        assertEquals(1, SampleStore.diff.count { it.kind == SampleStore.ChangeKind.REMOVED })
        assertEquals(1, SampleStore.diff.count { it.kind == SampleStore.ChangeKind.ADDED })
        val removed = SampleStore.diff.single { it.kind == SampleStore.ChangeKind.REMOVED }
        val added = SampleStore.diff.single { it.kind == SampleStore.ChangeKind.ADDED }
        assertTrue(removed.text.contains("Welcome to our site"))
        assertTrue(added.text.contains("Fresh bread, daily, on Mill Street"))
    }

    @Test
    fun readingsAreLabelledInvented() {
        assertEquals(3, SampleStore.readings.size)
        assertTrue(SampleStore.disclaimer.contains("invented"))
        assertTrue(SampleStore.disclaimer.contains("not anybody's usage"))
    }
}
