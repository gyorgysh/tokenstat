// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.search

import ai.tokenstat.tokenstat.ui.workspace.ChatDisplayItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedWorkTranscriptTest {
    @Test
    fun emptyTranscriptIsNull() {
        assertNull(SavedWork.transcript(emptyList(), hasEarlier = false))
        assertNull(
            SavedWork.transcript(
                listOf(ChatDisplayItem.Thinking("t1", "thinking")),
                hasEarlier = false,
            ),
        )
    }

    @Test
    fun keepsUserAndAssistantInOrderAndMarksEarlier() {
        val copy = SavedWork.transcript(
            listOf(
                ChatDisplayItem.User("u1", "Hello"),
                ChatDisplayItem.Thinking("t1", "plan"),
                ChatDisplayItem.Assistant("a1", "Hi there", backend = null),
            ),
            hasEarlier = true,
        )
        assertNotNull(copy)
        assertTrue(copy!!.partial)
        assertTrue(copy.text.contains("Hello"))
        assertTrue(copy.text.contains("Hi there"))
        assertFalse(copy.text.contains("plan"))
        assertEquals(copy.text.indexOf("Hello") < copy.text.indexOf("Hi there"), true)
    }

    @Test
    fun capsAGiantReplyAndMarksPartial() {
        val huge = "x".repeat(400_000)
        val copy = SavedWork.transcript(
            listOf(ChatDisplayItem.Assistant("a1", huge, backend = null)),
            hasEarlier = false,
        )
        assertNotNull(copy)
        assertTrue(copy!!.partial)
        assertTrue(copy.text.endsWith("…"))
        assertTrue(copy.text.length < 310_000)
    }
}
