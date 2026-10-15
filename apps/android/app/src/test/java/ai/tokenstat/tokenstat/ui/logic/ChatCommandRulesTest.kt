// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic
import org.junit.Assert.assertEquals
import org.junit.Test
class ChatCommandRulesTest {
    @Test fun `local commands are independent of the backend and native compaction is explicit`() {
        val rules = ChatCommandRules
        assertEquals("chat.compact", rules.sendMethod(" /compact "))
        assertEquals("chat.send", rules.sendMethod("please /compact"))
        for (backend in listOf("claude", "codex", "cursor", "muse", "opencode", "opencode2", "grok", "agy", "sh")) {
            rules.names.filter { it !in listOf("/compact", "/stop") }.forEach {
                assertEquals(ChatCommandRules.Kind.INSPECT, rules.action(it, backend, true, false).kind)
            }
            assertEquals(if (backend in listOf("claude", "codex")) ChatCommandRules.Kind.COMPACT else ChatCommandRules.Kind.UNSUPPORTED,
                rules.action("/compact", backend, false, false).kind)
        }
        assertEquals("/status", rules.action("/sta", "sh", true, false).completion)
        assertEquals(ChatCommandRules.Kind.RUNNING, rules.action("/compact", "codex", true, false).kind)
        assertEquals(ChatCommandRules.Kind.ARGUMENTS, rules.action("/status\nhello", "claude", false, false).kind)
        assertEquals(ChatCommandRules.Kind.ATTACHMENTS, rules.action("/status", "claude", false, true).kind)
        assertEquals(ChatCommandRules.Kind.MESSAGE, rules.action("/usr/local/file", "sh", false, false).kind)
        assertEquals(ChatCommandRules.Kind.STOP, rules.action("/stop", "sh", true, false).kind)
    }
}
