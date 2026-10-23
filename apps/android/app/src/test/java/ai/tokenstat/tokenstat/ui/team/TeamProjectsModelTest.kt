// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TeamProjectsModelTest {
    private fun account() = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "fictional"); put("accountId", "self"); put("accountSession", "session") }
    private fun row(id: String, organization: String? = null, role: String? = "viewer") = buildJsonObject {
        put("id", id); put("name", "Fictional $id"); organization?.let { put("organizationId", it); put("role", role?.let(::JsonPrimitive) ?: JsonNull) }
    }
    private fun page(field: String, rows: List<JsonObject>, next: Int? = null) = buildJsonObject { put(field, JsonArray(rows)); put("nextOffset", next?.let(::JsonPrimitive) ?: JsonNull) }
    @Test fun discoversAssignedProjectsAcrossTeamsAndLaterPagesWithTheOriginalAccount() = runTest {
        val seen = mutableListOf<JsonObject>()
        val calls = TeamCalls(account()) { method, fields ->
            assertEquals("teams.directory", method); assertEquals("session", fields.teamString("_accountSession")); seen += fields
            val offset = fields["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int
            when (fields.teamString("operation")) {
                "organizations.list" -> if (offset == 0) page("organizations", listOf(row("first")), 100) else page("organizations", listOf(row("later")))
                "repositories.list" -> if (offset == 0) page("repositories", listOf(row("unassigned", fields.teamString("organization"), null)), 100)
                    else page("repositories", listOf(row("assigned", fields.teamString("organization"), "contributor")))
                else -> error("Unexpected operation")
            }
        }
        val model = TeamProjectsModel(calls); model.loadOrganizations(); model.loadOrganizations(true)
        assertEquals(listOf("first", "later"), model.organizations.rows.map { it.teamString("id") })
        model.loadProjects("later"); assertTrue(model.projects["later"]!!.rows.isEmpty()); assertEquals(100, model.projects["later"]!!.next)
        model.loadProjects("later", true); assertEquals("assigned", model.projects["later"]!!.rows.single().teamString("id"))
        assertTrue(seen.filter { it.teamString("operation") == "repositories.list" }.all { it.teamString("organization") == "later" })
    }
    @Test fun laterFailureKeepsLoadedProjectsAndRetriesTheSameOffset() = runTest {
        var fail = true; val offsets = mutableListOf<Int>()
        val calls = TeamCalls(account()) { _, fields ->
            if (fields.teamString("operation") == "organizations.list") page("organizations", listOf(row("team")))
            else {
                val offset = fields["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int; offsets += offset
                if (offset == 0) page("repositories", listOf(row("one", "team")), 100)
                else if (fail) { fail = false; error("Fictional outage") }
                else page("repositories", listOf(row("two", "team")))
            }
        }
        val model = TeamProjectsModel(calls); model.loadOrganizations(); model.loadProjects("team"); model.loadProjects("team", true)
        assertEquals("one", model.projects["team"]!!.rows.single().teamString("id")); assertNotNull(model.errors["team"])
        model.loadProjects("team", true)
        assertEquals(listOf(0, 100, 100), offsets); assertEquals(2, model.projects["team"]!!.rows.size); assertNull(model.errors["team"])
    }
    @Test fun refreshingRetiresHeldOldProjectPagesAndRejectsForeignTeamRows() = runTest {
        val pending = CompletableDeferred<JsonObject>(); var held = true
        val calls = TeamCalls(account()) { _, fields ->
            if (fields.teamString("operation") == "organizations.list") page("organizations", listOf(row("team")))
            else if (held) { held = false; pending.await() } else page("repositories", listOf(row("foreign", "other-team")))
        }
        val model = TeamProjectsModel(calls); model.loadOrganizations()
        val old = launch { model.loadProjects("team") }; runCurrent()
        model.loadOrganizations(); pending.complete(page("repositories", listOf(row("stale", "team")))); old.join()
        assertTrue(model.projects.isEmpty()); assertTrue(model.loading.isEmpty())
        model.loadProjects("team"); assertTrue(model.projects.isEmpty()); assertNotNull(model.errors["team"])
    }
}
