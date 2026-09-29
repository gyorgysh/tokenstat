// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// An empty chat left behind by New chat is not a conversation, and a list
/// of them hides the ones that are. Anything with a word in it stays.
class UntouchedChatsTest {
    @Test
    fun `an unused chat with the default title is left out`() {
        assertTrue(UntouchedChats.isUntouched("New chat", null, running = false, id = "a"))
    }

    @Test
    fun `a chat with a message stays`() {
        assertFalse(UntouchedChats.isUntouched("New chat", 1_700_000_000_000, running = false, id = "a"))
    }

    @Test
    fun `a renamed chat stays even from a host without message times`() {
        assertFalse(UntouchedChats.isUntouched("fix the login", null, running = false, id = "a"))
    }

    @Test
    fun `a running first turn stays`() {
        assertFalse(UntouchedChats.isUntouched("New chat", null, running = true, id = "a"))
    }

    @Test
    fun `the open chat stays while it is open`() {
        assertFalse(UntouchedChats.isUntouched("New chat", null, running = false, id = "a", openId = "a"))
        assertTrue(UntouchedChats.isUntouched("New chat", null, running = false, id = "a", openId = "b"))
    }
}
