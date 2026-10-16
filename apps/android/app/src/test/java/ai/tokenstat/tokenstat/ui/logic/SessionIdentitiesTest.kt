// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SessionIdentitiesTest {
    private fun objectValue(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun identities(entries: JsonArray, total: Int = entries.size) = buildJsonObject {
        put("entries", entries); put("total", total); put("truncated", false)
    }
    private fun row(backend: String, id: String, status: String = "current", lastSeen: Long = 0) = buildJsonObject {
        put("backend", backend); put("id", id); put("status", status); put("lastSeenAtMs", lastSeen)
    }
    private fun chat(value: JsonObject) = parseChatSessionIdentities(buildJsonObject { put("sessions", value) })

    @Test fun olderHostsNeverTurnResumeTokensOrArbitrarySessionFieldsIntoVisibleIds() {
        val older = objectValue("""{"resumeToken":"credential","sessionId":"unverified","resumeTokens":{"codex":"credential"},"meter":{"sessions":{"entries":[{"backend":"codex","id":"nested-id","status":"current"}]}}}""")
        assertEquals(SessionIdentities(), parseChatSessionIdentities(older))
        assertEquals(SessionIdentities(), parseTerminalSessionIdentities(older))
        assertEquals(SessionIdentities(), parseChatSessionIdentities(null))
    }

    @Test fun allAttestedStatusesAndSourceConversationSurviveBackendHandoffs() {
        val value = identities(JsonArray(listOf(
            row("claude", "11111111-1111-4111-8111-111111111111", "historical", 3),
            row("grok", "22222222-2222-4222-8222-222222222222", "saved", 4),
            JsonObject(row("codex", "33333333-3333-4333-8333-333333333333", "current", 5) + mapOf("sourceConversationId" to JsonPrimitive("chat-source"), "firstSeenAtMs" to JsonPrimitive(1))),
        )))
        val result = chat(value)
        assertEquals(listOf("33333333-3333-4333-8333-333333333333", "22222222-2222-4222-8222-222222222222", "11111111-1111-4111-8111-111111111111"), result.entries.map { it.id })
        assertEquals(listOf(SessionIdentityStatus.Current, SessionIdentityStatus.Saved, SessionIdentityStatus.Historical), result.entries.map { it.status })
        assertEquals("chat-source", result.entries.first().sourceConversationId)
        assertEquals(listOf("chat-source"), result.sourceConversationIds)
        assertEquals(1L, result.entries.first().firstSeenAtMs)
        assertEquals(3, result.total)
        assertFalse(result.truncated)
    }

    @Test fun terminalReadsOnlyTheApprovedTopLevelProjection() {
        val value = identities(JsonArray(listOf(row("claude", "44444444-4444-4444-8444-444444444444"))))
        val info = buildJsonObject {
            put("id", "tokenstat-terminal")
            put("sessionIdentities", value)
            put("meter", buildJsonObject { put("sessions", identities(JsonArray(listOf(row("codex", "wrong-nested-session"))))) })
        }
        assertEquals(listOf("44444444-4444-4444-8444-444444444444"), parseTerminalSessionIdentities(info).entries.map { it.id })
        assertEquals(SessionIdentities(), parseChatSessionIdentities(info))
    }

    @Test fun malformedEntriesAndResumeObjectsAreNeverRenderedAsIdentifiers() {
        val rows = JsonArray(listOf(
            row("codex", "55555555-5555-4555-8555-555555555555"), row("codex", "66666666-6666-4666-8666-666666666666", "future-state"),
            row("codex", "line\nbreak"), row("codex", " leading"), row("codex", "{\"token\":\"secret\"}"),
            row("codex", "x".repeat(513)), row("bad backend", "session"),
            buildJsonObject { put("backend", "codex"); put("id", buildJsonObject { put("token", "secret") }); put("status", "current") },
            buildJsonObject { put("backend", "codex"); put("id", 123); put("status", "current") },
        ))
        val parsed = chat(identities(rows))
        assertEquals(listOf("55555555-5555-4555-8555-555555555555", "66666666-6666-4666-8666-666666666666"), parsed.entries.map { it.id })
        assertEquals(SessionIdentityStatus.Historical, parsed.entries.last().status)
        assertEquals(SessionIdentities(), chat(objectValue("""{"entries":{}}""")))
    }

    @Test fun duplicateEntriesPreferCurrentWithoutMergingDifferentBackends() {
        val result = chat(identities(JsonArray(listOf(
            row("codex", "77777777-7777-4777-8777-777777777777", "historical", 10), row("codex", "77777777-7777-4777-8777-777777777777", "current", 5),
            row("claude", "77777777-7777-4777-8777-777777777777", "saved", 4),
        ))))
        assertEquals(2, result.entries.size)
        assertEquals(SessionIdentityStatus.Current, result.entries.first().status)
        assertEquals("codex", result.entries.first().backend)
        assertEquals("claude", result.entries.last().backend)
    }

    @Test fun historiesAreBoundedAndExposeTheReportedTotalAndTruncation() {
        val result = chat(identities(JsonArray((0 until 100).map { row("codex", "%08x-1111-4111-8111-%012x".format(it, it), "historical", it.toLong()) }), total = 150))
        assertEquals(64, result.entries.size)
        assertEquals("00000063-1111-4111-8111-000000000063", result.entries.first().id)
        assertEquals(150, result.total)
        assertTrue(result.truncated)
    }

    @Test fun mergedNativeIdsPreserveEveryBoundedSourceConversationReference() {
        val rows = JsonArray((0 until 100).map { index ->
            JsonObject(row("codex", "88888888-8888-4888-8888-888888888888", if (index == 0) "current" else "historical") +
                ("sourceConversationId" to JsonPrimitive("chat-$index")))
        } + JsonObject(row("codex", "88888888-8888-4888-8888-888888888888") + ("sourceConversationId" to JsonPrimitive("chat-0"))))
        val result = chat(identities(rows))
        assertEquals(1, result.entries.size)
        assertEquals(64, result.sourceConversationIds.size)
        assertEquals("chat-0", result.sourceConversationIds.first())
        assertEquals("chat-63", result.sourceConversationIds.last())
        assertTrue(result.sourceConversationIds.distinct().size == result.sourceConversationIds.size)
    }

    @Test fun nativeFormatsAndSourceReferencesMatchTheHostAndOtherClients() {
        val valid = "99999999-9999-4999-8999-999999999999"
        val code = "ses_012345abcdef0123456789abcd"
        val rows = JsonArray(listOf(
            row("codex", "opaque-credential"), row("future_agent", valid),
            row("codex", "00000000-0000-0000-0000-000000000000"),
            row("codex", valid.replace("-", "")), row("opencode", "ses_secret"),
            row("opencode2", code, "future-state"),
            JsonObject(row("claude", valid, "saved") + ("sourceConversationId" to JsonPrimitive("/private/transcript"))),
            JsonObject(row("grok", valid) + ("sourceConversationId" to JsonPrimitive("chat{secret"))),
        ))
        val result = chat(identities(rows))
        assertEquals(listOf("grok", "claude", "opencode2"), result.entries.map { it.backend })
        assertEquals(SessionIdentityStatus.Historical, result.entries.last().status)
        assertTrue(result.sourceConversationIds.isEmpty())
        assertNull(result.entries.first().firstSeenAtMs)
    }
}
