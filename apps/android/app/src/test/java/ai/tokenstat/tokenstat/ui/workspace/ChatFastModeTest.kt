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
        for (model in listOf("opus", "opus[1m]", "claude-opus-5-5", "claude-opus-4-8-20260525")) {
            assertTrue(chatFastModeAvailable(model, models))
        }
        for (model in listOf(null, "sonnet", "haiku", "claude-opus-4-7", "claude-opus-5-9")) {
            assertFalse(chatFastModeAvailable(model, models))
        }
        assertFalse(chatFastModeOn(Json.parseToJsonElement("{}") as JsonObject))
        assertTrue(chatFastModeOn(Json.parseToJsonElement("""{"fastMode":true}""") as JsonObject))
        assertFalse(chatFastModeOn(Json.parseToJsonElement("""{"fastMode":false}""") as JsonObject))
    }
}
