// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChatRelayAllowanceTest {
    private fun account(vararg changes: Pair<String, JsonElement>) = buildJsonObject {
        put("relayUsage", JsonObject(buildJsonObject {
            put("policy", "rolling_30_utc_days"); put("windowDays", 30); put("timezone", "UTC")
            put("usedBytes", 40); put("limitBytes", 100); put("remainingBytes", 60)
        }.toMutableMap().apply { putAll(changes) }))
    }
    @Test fun usesServerCountersAndBoundsTheIndicator() {
        assertEquals(ChatRelayAllowance(40, 100, 60), ChatRelayAllowance.from(account()))
        assertEquals(0.4f, ChatRelayAllowance.from(account())!!.fraction)
        assertEquals(1f, ChatRelayAllowance.from(account("usedBytes" to JsonPrimitive(Long.MAX_VALUE)))!!.fraction)
        assertEquals(0f, ChatRelayAllowance.from(account("limitBytes" to JsonPrimitive(0)))!!.fraction)
    }
    @Test fun unknownPoliciesAndIncompleteCountersRemainUnknown() {
        assertNull(ChatRelayAllowance.from(null))
        for ((key, value) in listOf("policy" to JsonPrimitive("new_policy"), "windowDays" to JsonPrimitive(7),
            "timezone" to JsonPrimitive("other"), "usedBytes" to JsonPrimitive(-1),
            "limitBytes" to JsonNull, "remainingBytes" to JsonPrimitive("unavailable"))) {
            assertNull(ChatRelayAllowance.from(account(key to value)))
        }
    }
}
