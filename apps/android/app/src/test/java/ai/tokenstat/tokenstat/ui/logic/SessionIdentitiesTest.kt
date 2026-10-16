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
            row("claude", "older-session", "historical", 3),
            row("grok", "saved-session", "saved", 4),
            JsonObject(row("codex", "active-session", "current", 5) + mapOf("sourceConversationId" to JsonPrimitive("chat-source"), "firstSeenAtMs" to JsonPrimitive(1))),
        )))
        val result = chat(value)
        assertEquals(listOf("active-session", "saved-session", "older-session"), result.entries.map { it.id })
        assertEquals(listOf(SessionIdentityStatus.Current, SessionIdentityStatus.Saved, SessionIdentityStatus.Historical), result.entries.map { it.status })
        assertEquals("chat-source", result.entries.first().sourceConversationId)
        assertEquals(listOf("chat-source"), result.sourceConversationIds)
        assertEquals(1L, result.entries.first().firstSeenAtMs)
        assertEquals(3, result.total)
        assertFalse(result.truncated)
    }

    @Test fun terminalReadsOnlyTheApprovedTopLevelProjection() {
        val value = identities(JsonArray(listOf(row("claude", "pty-agent-session"))))
        val info = buildJsonObject {
            put("id", "tokenstat-terminal")
            put("sessionIdentities", value)
            put("meter", buildJsonObject { put("sessions", identities(JsonArray(listOf(row("codex", "wrong-nested-session"))))) })
        }
        assertEquals(listOf("pty-agent-session"), parseTerminalSessionIdentities(info).entries.map { it.id })
        assertEquals(SessionIdentities(), parseChatSessionIdentities(info))
    }

    @Test fun malformedEntriesAndResumeObjectsAreNeverRenderedAsIdentifiers() {
        val rows = JsonArray(listOf(
            row("codex", "valid-id"), row("codex", "unknown-status", "future-state"),
            row("codex", "line\nbreak"), row("codex", " leading"), row("codex", "{\"token\":\"secret\"}"),
            row("codex", "x".repeat(513)), row("bad backend", "session"),
            buildJsonObject { put("backend", "codex"); put("id", buildJsonObject { put("token", "secret") }); put("status", "current") },
            buildJsonObject { put("backend", "codex"); put("id", 123); put("status", "current") },
        ))
        val parsed = chat(identities(rows))
        assertEquals(listOf("valid-id", "unknown-status"), parsed.entries.map { it.id })
        assertEquals(SessionIdentityStatus.Historical, parsed.entries.last().status)
        assertEquals(SessionIdentities(), chat(objectValue("""{"entries":{}}""")))
    }

    @Test fun duplicateEntriesPreferCurrentWithoutMergingDifferentBackends() {
        val result = chat(identities(JsonArray(listOf(
            row("codex", "shared-id", "historical", 10), row("codex", "shared-id", "current", 5),
            row("claude", "shared-id", "saved", 4),
        ))))
        assertEquals(2, result.entries.size)
        assertEquals(SessionIdentityStatus.Current, result.entries.first().status)
        assertEquals("codex", result.entries.first().backend)
        assertEquals("claude", result.entries.last().backend)
    }

    @Test fun historiesAreBoundedAndExposeTheReportedTotalAndTruncation() {
        val result = chat(identities(JsonArray((0 until 100).map { row("codex", "session-$it", "historical", it.toLong()) }), total = 150))
        assertEquals(64, result.entries.size)
        assertEquals("session-99", result.entries.first().id)
        assertEquals(150, result.total)
        assertTrue(result.truncated)
    }

    @Test fun mergedNativeIdsPreserveEveryBoundedSourceConversationReference() {
        val rows = JsonArray((0 until 100).map { index ->
            JsonObject(row("codex", "same-native-id", if (index == 0) "current" else "historical") +
                ("sourceConversationId" to JsonPrimitive("chat-$index")))
        } + JsonObject(row("codex", "same-native-id") + ("sourceConversationId" to JsonPrimitive("chat-0"))))
        val result = chat(identities(rows))
        assertEquals(1, result.entries.size)
        assertEquals(64, result.sourceConversationIds.size)
        assertEquals("chat-0", result.sourceConversationIds.first())
        assertEquals("chat-63", result.sourceConversationIds.last())
        assertTrue(result.sourceConversationIds.distinct().size == result.sourceConversationIds.size)
    }

    @Test fun futureBackendNamesAndMissingOptionalTimestampsRemainCompatible() {
        val result = chat(objectValue("""{"entries":[{"backend":"future_agent","id":"session-id","status":"saved"}],"total":1}"""))
        assertEquals("future_agent", result.entries.single().backend)
        assertNull(result.entries.single().firstSeenAtMs)
        assertNull(result.entries.single().lastSeenAtMs)
    }
}
