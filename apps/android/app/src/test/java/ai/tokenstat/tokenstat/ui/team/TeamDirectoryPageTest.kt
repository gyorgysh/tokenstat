// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TeamDirectoryPageTest {
    private fun row(n: Int) = buildJsonObject { put("id", "row-$n"); put("checkoutId", "computer") }
    private fun answer(key: String, rows: List<JsonObject>, next: Pair<String, JsonElement>? = null) = buildJsonObject {
        put(key, JsonArray(rows)); next?.let { put(it.first, it.second) }
    }
    @Test fun laterComputersAndCatalogRowsAreReachableAndBoundaryRepeatsAreDeduplicated() {
        val first = TeamDirectoryPage.read(answer("checkouts", (0..2).map(::row), "nextOffset" to JsonPrimitive(3)), "checkouts", 0)
        val next = TeamDirectoryPage.read(answer("checkouts", listOf(row(3))), "checkouts", first.next!!)
        assertEquals(4, TeamCatalogPage.append(first.rows, next.rows).size); assertNull(next.next)
        val catalog = TeamCatalogPage.read(answer("shares", (0..49).map(::row), "nextCursor" to JsonPrimitive("next-page")), "computer", null)
        val final = TeamCatalogPage.read(answer("shares", listOf(row(49), row(50))), "computer", catalog.next)
        assertEquals(51, TeamCatalogPage.append(catalog.rows, final.rows).size)
    }
    @Test fun malformedOrStationaryCursorsAndForeignCatalogRowsAreRefused() {
        assertTrue(runCatching { TeamDirectoryPage.read(answer("checkouts", listOf(row(1)), "nextOffset" to JsonPrimitive(3)), "checkouts", 3) }.isFailure)
        assertTrue(runCatching { TeamDirectoryPage.read(answer("checkouts", listOf(row(1)), "nextOffset" to JsonPrimitive("4")), "checkouts", 3) }.isFailure)
        assertTrue(runCatching { TeamCatalogPage.read(answer("shares", listOf(row(1)), "nextCursor" to JsonPrimitive("same")), "computer", "same") }.isFailure)
        assertTrue(runCatching { TeamCatalogPage.read(answer("shares", listOf(row(1))), "another-computer", null) }.isFailure)
        assertTrue(runCatching { TeamCatalogPage.read(answer("shares", listOf(row(1), row(1))), "computer", null) }.isFailure)
        assertEquals("next", TeamCatalogPage.read(answer("shares", emptyList(), "nextCursor" to JsonPrimitive("next")), "computer", null).next)
    }
    @Test fun publisherBackendMetadataIsOptionalFilteredUniqueAndBounded() {
        fun option(id: String, label: JsonElement? = null) = buildJsonObject { put("id", id); label?.let { put("label", it) } }
        val ids = listOf("claude", "codex", "muse", "grok", "cursor", "agy", "opencode", "opencode2")
        val catalog = buildJsonObject { put("shares", JsonArray(emptyList())); put("backends", JsonArray(ids.map { option(it, JsonPrimitive("Publisher $it")) })) }
        val advertised = TeamCatalogPage.read(catalog, "computer", null).backends
        assertEquals(ids, advertised.map { it.id }); assertEquals("Publisher agy", advertised[5].label)
        assertTrue(TeamCatalogPage.read(answer("shares", emptyList()), "computer", null).backends.isEmpty())
        assertTrue(TeamBackendOption.read(JsonObject(emptyMap())).isEmpty())
        val invalid = listOf(JsonNull, option(""), option("UPPER"), option("slash/name"), option("é"), option("x".repeat(65)),
            option("blank", JsonPrimitive("  ")), option("long", JsonPrimitive("x".repeat(129))), option("wrong", JsonPrimitive(4)),
            option("multiline", JsonPrimitive("Agent\nname")), option("hidden", JsonPrimitive("\u200b")))
        val filtered = TeamBackendOption.read(JsonArray(invalid + listOf(option("claude", JsonPrimitive("First")), option("claude", JsonPrimitive("Duplicate")), option("future-agent_v2"))))
        assertEquals(listOf(TeamBackendOption("claude", "First"), TeamBackendOption("future-agent_v2", "future-agent_v2")), filtered)
        val bounded = TeamBackendOption.read(JsonArray((0..<1000).map { option("agent-$it") }))
        assertEquals(32, bounded.size); assertEquals("agent-31", bounded.last().id)
        val duplicates = JsonArray(List(32) { option("claude") } + option("outside-cap"))
        val invalidPrefix = JsonArray(List(32) { JsonNull } + option("outside-cap"))
        assertEquals(listOf("claude"), TeamBackendOption.read(duplicates).map { it.id })
        assertTrue(TeamBackendOption.read(invalidPrefix).isEmpty())
    }
}
