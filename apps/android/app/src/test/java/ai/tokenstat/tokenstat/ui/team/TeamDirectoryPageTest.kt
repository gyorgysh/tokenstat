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
}
