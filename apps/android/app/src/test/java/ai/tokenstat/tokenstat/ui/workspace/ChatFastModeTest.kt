// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatFastModeTest {
    @Test fun `older hosts and unsupported models never enable paid fast mode`() {
        val models = Json.parseToJsonElement("""["opus","claude-opus-5-5","claude-opus-5","claude-opus-4-8"]""") as JsonArray
        assertFalse(chatFastModeAvailable("opus", null))
        assertTrue(chatFastModeAvailable(null, JsonArray(emptyList())))
        val grok = Json.parseToJsonElement("""["grok-4.7", ""]""") as JsonArray
        assertTrue(chatFastModeAvailable(null, grok, "grok"))
        assertTrue(chatFastModeAvailable("grok-4.7", grok, "grok"))
        for (model in listOf("grok-4.6", "-20261006", "grok-4.7-20261006", "grok-4.7[1m]")) {
            assertFalse(chatFastModeAvailable(model, grok, "grok"))
        }
        assertFalse(chatFastModeAvailable(null, JsonArray(emptyList()), "grok"))
        assertFalse(chatFastModeAvailable(null, Json.parseToJsonElement("""["grok-4.7"]""") as JsonArray, "grok"))
        assertTrue(chatFastModeAvailable("grok-4.7-20261006", Json.parseToJsonElement("""["grok-4.7-20261006"]""") as JsonArray, "grok"))
        for (model in listOf("opus", "opus[1m]", "claude-opus-5-5", "claude-opus-5-5[1m]", "claude-opus-4-8-20260525", "claude-opus-4-8-20260525[1m]")) {
            assertTrue(chatFastModeAvailable(model, models))
        }
        for (model in listOf(null, "sonnet", "haiku", "claude-opus-4-7", "claude-opus-5-9", "claude-opus-5-9[1m]", "claude-opus-4-7-20260416[1m]", "opus[bogus]")) {
            assertFalse(chatFastModeAvailable(model, models))
        }
        assertFalse(chatFastModeOn(Json.parseToJsonElement("{}") as JsonObject))
        assertTrue(chatFastModeOn(Json.parseToJsonElement("""{"fastMode":true}""") as JsonObject))
        assertFalse(chatFastModeOn(Json.parseToJsonElement("""{"fastMode":false}""") as JsonObject))
    }
}
