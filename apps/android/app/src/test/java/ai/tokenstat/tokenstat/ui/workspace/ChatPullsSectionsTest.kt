// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChatPullsSectionsTest {
    @Test
    fun `send carries the conversation revision`() {
        val params = chatSendParams("chat-1", "hi", "msg-1", 123L, 7L)
        assertEquals(7L, (params["expectedRevision"] as? JsonPrimitive)?.longOrNull)
    }

    @Test
    fun `send omits the revision when unknown`() {
        val params = chatSendParams("chat-1", "hi", "msg-1", 123L, null)
        assertNull(params["expectedRevision"])
    }

    @Test
    fun `backend options skip uninstalled agents`() {
        val backends = listOf(
            buildJsonObject {
                put("id", JsonPrimitive("opencode"))
                put("label", JsonPrimitive("OpenCode"))
                put("installed", JsonPrimitive(true))
            },
            buildJsonObject {
                put("id", JsonPrimitive("sh"))
                put("installed", JsonPrimitive(false))
            },
        )
        assertEquals(listOf("opencode" to "OpenCode"), chatBackendOptions(backends))
    }

    @Test
    fun `model options keep the current model`() {
        val backend = buildJsonObject {
            put("models", buildJsonArray {
                add(JsonPrimitive("a"))
            })
        }
        assertEquals(listOf("a", "b"), chatModelOptions(backend, "b"))
        assertEquals(listOf("a"), chatModelOptions(backend, null))
    }

    @Test
    fun `delivery claims current saved text and never resurrects a removed message`() {
        val items = mutableListOf(ai.tokenstat.tokenstat.ui.logic.QueuedMessage("one", "edited", expectedRevision = 3))
        assertNull(prepareQueuedDelivery(items, "removed", 10, "replacement"))
        val attempt = prepareQueuedDelivery(items, "one", 10, "replacement")!!
        assertEquals("edited", attempt.text)
        assertEquals(attempt, items.single())
        assertEquals(ai.tokenstat.tokenstat.ui.logic.ChatDelivery.Sending, attempt.delivery)
        assertNull(prepareQueuedDelivery(items, "one", 11, "replacement"))
    }

    @Test
    fun `edited retry rotates receipt identity while review stays blocked`() {
        val items = mutableListOf(ai.tokenstat.tokenstat.ui.logic.QueuedMessage(
            "old", "edited", expectedRevision = 3, attemptedAtMs = 1, firstAttemptAtMs = 1))
        val attempt = prepareQueuedDelivery(items, "old", 10, "new")!!
        assertEquals("new", attempt.id)
        assertEquals(10L, attempt.firstAttemptAtMs)
        items[0] = attempt.copy(delivery = ai.tokenstat.tokenstat.ui.logic.ChatDelivery.NeedsReview)
        assertNull(prepareQueuedDelivery(items, "new", 11, "other"))
    }

    @Test
    fun `failed note capture retains writing typed during its save`() {
        assertEquals("failed\n\nnew writing", restoreFailedNoteDraft("failed", "new writing"))
        assertEquals("failed", restoreFailedNoteDraft("failed", "  "))
    }
}
