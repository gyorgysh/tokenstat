// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The persona readers must be total: the host answers with shapes older
/// answers did not carry, and a reader that throws on those is a crash on the
/// sheet that uses it.
class PersonaModelsTest {
    private fun personaJson() = buildJsonObject {
        put("id", "p1")
        put("workspaceId", "w1")
        put("name", "Reviewer")
        put("systemPrompt", "Review carefully.")
        put("seed", 99L)
    }

    @Test
    fun parsesPersona() {
        val persona = parseChatPersona(personaJson())!!
        assertEquals("p1", persona.id)
        assertEquals("w1", persona.workspaceId)
        assertEquals("Reviewer", persona.name)
        assertEquals("Review carefully.", persona.systemPrompt)
        assertEquals(99UL, persona.seed)
    }

    @Test
    fun nullWorkspaceIsShared() {
        val element = buildJsonObject {
            put("id", "p1")
            put("workspaceId", JsonNull)
            put("name", "Shared")
            put("systemPrompt", "")
        }
        assertNull(parseChatPersona(element)!!.workspaceId)
    }

    @Test
    fun missingIdIsNoPersona() {
        assertNull(parseChatPersona(buildJsonObject { put("name", "Nameless") }))
        assertNull(parseChatPersona(JsonPrimitive("nope")))
        assertNull(parseChatPersona(null))
    }

    @Test
    fun parsesListWithDefault() {
        val element = buildJsonObject {
            put("personas", buildJsonArray { add(personaJson()) })
            put("defaultId", "p1")
        }
        val (personas, defaultId) = parseChatPersonaList(element)
        assertEquals(1, personas.size)
        assertEquals("p1", defaultId)
    }

    @Test
    fun bareArrayReadsAsListWithNoDefault() {
        val (personas, defaultId) = parseChatPersonaList(buildJsonArray { add(personaJson()) })
        assertEquals(1, personas.size)
        assertNull(defaultId)
    }

    @Test
    fun emptyDefaultIdIsNoDefault() {
        val element = buildJsonObject {
            put("personas", buildJsonArray { add(personaJson()) })
            put("defaultId", "")
        }
        assertNull(parseChatPersonaList(element).second)
    }

    @Test
    fun parsesDraft() {
        val draft = parseChatPersonaDraft(
            buildJsonObject {
                put("name", "Helper")
                put("systemPrompt", "Helps.")
            },
        )!!
        assertEquals("Helper", draft.name)
        assertEquals("Helps.", draft.systemPrompt)
    }

    @Test
    fun shellBackendDraftsNothing() {
        val element = buildJsonArray {
            add(buildJsonObject { put("id", "sh"); put("label", "Shell") })
            add(buildJsonObject { put("id", "claude"); put("label", "Claude") })
        }
        val backends = parsePersonaBackends(element)
        assertEquals(1, backends.size)
        assertEquals("claude", backends.single().id)
    }

    @Test
    fun backendsFallBackToNameThenId() {
        val element = buildJsonArray {
            add(buildJsonObject { put("id", "a"); put("name", "Agent A") })
            add(buildJsonObject { put("id", "b") })
        }
        val backends = parsePersonaBackends(element)
        assertEquals("Agent A", backends[0].label)
        assertEquals("b", backends[1].label)
    }

    @Test
    fun faceSeedPrefersStoredSeed() {
        val stored = ChatPersona("p", "w", "N", "S", 123UL)
        assertEquals(123UL, faceSeedFor(stored))
        val unsettled = ChatPersona("p", "w", "N", "S", 0UL)
        assertEquals(personaSeed("N"), faceSeedFor(unsettled))
        val nameless = ChatPersona("p", "w", "", "Brief words", 0UL)
        assertEquals(personaSeed("Brief words"), faceSeedFor(nameless))
    }

    @Test
    fun saveParamsCarryPersonaAndScope() {
        val params = personaSaveParams(ChatPersona("p1", null, "N", "S", 5UL), "w1")
        val persona = params["persona"]!!.jsonObject
        assertEquals("p1", (persona["id"] as JsonPrimitive).contentOrNull)
        assertTrue(persona["workspaceId"] is JsonNull)
        assertEquals("w1", (params["workspaceId"] as JsonPrimitive).contentOrNull)
    }

    @Test
    fun draftParamsOmitBlankName() {
        val named = personaDraftParams("brief", "claude", "N")
        assertEquals("N", (named["name"] as JsonPrimitive).contentOrNull)
        val unnamed = personaDraftParams("brief", "claude", null)
        assertNull(unnamed["name"])
        val blank = personaDraftParams("brief", "claude", "  ")
        assertNull(blank["name"])
    }

    @Test
    fun blankStartsShared() {
        assertNull(ChatPersona.blank().workspaceId)
        assertEquals(0UL, ChatPersona.blank().seed)
    }
}
