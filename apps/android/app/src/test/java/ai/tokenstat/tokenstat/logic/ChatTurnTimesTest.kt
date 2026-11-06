// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.logic

import ai.tokenstat.tokenstat.ui.logic.ChatTurnTimes
import org.junit.Assert.*
import org.junit.Test

class ChatTurnTimesTest {
    @Test fun navigationKeepsTimeButCompletedTurnsAndSignOutRetireIt() {
        val state = ChatTurnTimes()
        assertEquals(100L, state.observe("account/host/chat", true, 100))
        assertEquals(100L, state.observe("account/host/chat", true, 1000))
        assertEquals(1000L, state.observe("other/host/chat", true, 1000))
        assertNull(state.observe("account/host/chat", false, 1100))
        assertEquals(1200L, state.observe("account/host/chat", true, 1200))
        state.clear()
        assertEquals(1300L, state.observe("other/host/chat", true, 1300))
        assertNull(state.observe(null, true, 1400))
    }
    @Test fun acceptedSendUsesItsStartInsteadOfTheLaterObservedReply() {
        val state = ChatTurnTimes()
        state.observe("chat", true, 1200)
        assertEquals(1000L, state.begin("chat", 1000))
        assertEquals(1000L, state.observe("chat", true, 2000))
    }
}
