// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Same rules as the Mac's `ChatPromptCacheRule`.
class ChatCacheRulesTest {
    private val hour = 3_600_000L

    private fun chat(cache: String?, backend: String = "claude"): JsonObject = Json.parseToJsonElement(
        """{"id":"c","backend":"$backend"${cache?.let { ",\"promptCache\":$it" } ?: ""}}""",
    ) as JsonObject

    private val big = """{"backend":"claude","tokens":435400,"model":"claude-sonnet-5-5","selection":"sonnet","atMs":1000,"ttlMs":$hour}"""

    @Test
    fun `an expired cache asks before sending`() {
        assertEquals(hour + 1, ChatCacheRules.idle(chat(big), 1000 + 2 * hour + 1)?.minus(hour))
        assertNull(ChatCacheRules.idle(chat(big), 1000 + hour))
    }

    @Test
    fun `a small conversation, another agent or an old host never asks`() {
        val small = big.replace("435400", "1200")
        assertNull(ChatCacheRules.idle(chat(small), 10 * hour))
        assertNull(ChatCacheRules.idle(chat(big, backend = "codex"), 10 * hour))
        assertNull(ChatCacheRules.idle(chat(null), 10 * hour))
    }

    @Test
    fun `only a warm cache on another model asks before switching`() {
        assertTrue(ChatCacheRules.switching(chat(big), "opus", 2000))
        assertFalse(ChatCacheRules.switching(chat(big), "sonnet", 2000))
        assertFalse(ChatCacheRules.switching(chat(big), "opus", 1000 + 2 * hour))
        assertEquals("claude-sonnet-5-5", ChatCacheRules.cachedModel(chat(big)))
    }

    @Test
    fun `numbers read like the usage screens`() {
        assertEquals("1d 17h", ChatCacheRules.duration((41L * 60) * 60_000))
        assertEquals("2h 5m", ChatCacheRules.duration(125L * 60_000))
        assertEquals("435.4k", ChatCacheRules.tokenCount(435_400))
    }
}
