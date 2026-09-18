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
}
