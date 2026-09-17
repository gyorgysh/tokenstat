// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// A finished turn needs no banner over the transcript it finished in, but
/// everything else still notifies: another machine's chat, a run, or an
/// unnamed push that cannot be attributed to what is on screen.
class VisibleChatTest {
    @Test
    fun `finished turn on the open machine stays quiet`() {
        VisibleChat.showing("m1", "chat-1")
        try {
            assertTrue(VisibleChat.suppresses(PushPayload.CHAT_FINISHED, "m1"))
            assertTrue(VisibleChat.suppresses(PushPayload.CHAT_FAILED, "m1"))
        } finally {
            VisibleChat.hidden()
        }
    }

    @Test
    fun `other machines and runs still notify`() {
        VisibleChat.showing("m1", "chat-1")
        try {
            assertFalse(VisibleChat.suppresses(PushPayload.CHAT_FINISHED, "m2"))
            assertFalse(VisibleChat.suppresses(PushPayload.CHAT_FINISHED, null))
            assertFalse(VisibleChat.suppresses(PushPayload.RUN_NEEDS_INPUT, "m1"))
            assertFalse(VisibleChat.suppresses(PushPayload.RUN_FINISHED, "m1"))
        } finally {
            VisibleChat.hidden()
        }
    }

    @Test
    fun `hidden screen notifies`() {
        VisibleChat.hidden()
        assertFalse(VisibleChat.suppresses(PushPayload.CHAT_FINISHED, "m1"))
    }
}
