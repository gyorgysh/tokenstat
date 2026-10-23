// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TeamManagementModelTest {
    private fun member(id: String, role: String, revision: Long = 5) = buildJsonObject {
        put("id", id); put("name", "Fictional $id"); put("role", role); put("revision", revision); put("eligible", true)
    }
    private fun organization(role: String = "owner", id: String = "org-fixture") = buildJsonObject {
        put("id", id); put("ownerId", "self"); put("name", "Fictional team"); put("role", role); put("revision", 7L); put("eligible", true); put("state", "active")
    }
    private fun repository(id: String = "repo-fixture") = buildJsonObject {
        put("id", id); put("organizationId", "org-fixture"); put("name", "Fictional project"); put("role", "maintainer")
    }
    private fun account() = buildJsonObject {
        put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "fictional"); put("accountId", "self"); put("accountSession", "fictional-session")
    }
    private fun refuses(action: () -> Unit) { assertTrue(runCatching(action).isFailure) }

    @Test fun reviewedMutationsKeepExactRevisionsAndNeverIncludeDirectoryPaging() = runTest {
        val seen = mutableListOf<JsonObject>()
        val calls = TeamCalls(account()) { method, fields ->
            assertEquals("teams.directory", method); assertEquals("fictional-session", fields.teamString("_accountSession"))
            seen += fields
            when (fields.teamString("operation")) {
                "organizations.get" -> buildJsonObject { put("organization", organization()) }
                "members.list" -> buildJsonObject { put("members", JsonArray(listOf(member("other", "member")))); put("nextOffset", JsonNull) }
                "repositories.list" -> buildJsonObject { put("repositories", JsonArray(listOf(repository()))); put("nextOffset", JsonNull) }
                else -> buildJsonObject {}
            }
        }
        val model = TeamManagementModel(calls, organization())
        assertFalse(model.manager)
        model.refresh("members"); model.refresh("repositories")
        val person = model.members.rows.single()
        model.mutate("members.role", model.memberRole(person, "admin"), user = person.teamString("id"))
        val grant = seen.last()
        assertEquals("org-fixture", grant.teamString("organization")); assertEquals("other", grant.teamString("user"))
        assertFalse(grant.containsKey("page")); assertEquals(5L, grant["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        assertEquals("admin", grant["input"]!!.jsonObject.teamString("role"))
        val invite = model.invite(" @Guest ", "member", emptyMap())
        assertEquals("guest", invite.teamString("handle")); assertEquals(JsonArray(emptyList()), invite["assignments"])
        model.mutate("invitations.create", invite)
        assertFalse(seen.last().containsKey("page"))
        assertFalse(seen.last()["input"]!!.jsonObject.containsKey("allowAgentRuns"))
        refuses { model.invite("guest", "member", mapOf("unreviewed-repo" to "maintainer")) }
        val access = model.access(repository(), person, null)
        assertEquals(JsonNull, access["role"]); assertEquals(5L, access["expectedRevision"]!!.jsonPrimitive.long)
        assertEquals(7L, model.rename(" Updated name ")["expectedRevision"]!!.jsonPrimitive.long)
        assertEquals("Updated name", model.rename(" Updated name ").teamString("name"))
    }
    @Test fun rolesAndStaleAuthorityFailClosedBeforeAnyPermissionWrite() = runTest {
        var role = "owner"; var wrong = false; var writes = 0
        val calls = TeamCalls(account()) { _, fields ->
            when (fields.teamString("operation")) {
                "organizations.get" -> buildJsonObject { put("organization", organization(role, if (wrong) "other-org" else "org-fixture")) }
                "members.list" -> buildJsonObject { put("members", JsonArray(listOf(member("other", "member")))); put("nextOffset", JsonNull) }
                else -> { writes++; buildJsonObject {} }
            }
        }
        val model = TeamManagementModel(calls, organization())
        model.refresh("members")
        refuses { model.memberRole(member("self", "owner"), "member") }
        refuses { model.removeMember(member("owner", "owner")) }
        refuses { model.memberRole(member("unknown", "unexpected"), "admin") }
        role = "admin"; model.refresh("members")
        assertTrue(model.manager); assertFalse(model.owner)
        refuses { model.memberRole(member("other", "member"), "admin") }
        refuses { model.removeMember(member("other-admin", "admin")) }
        refuses { model.invite("guest", "admin", emptyMap()) }
        assertTrue(runCatching { model.mutate("members.role", buildJsonObject {}, user = "other") }.isFailure)
        assertEquals(0, writes)
        wrong = true; model.refresh("members")
        assertFalse(model.verified); assertFalse(model.manager); assertEquals("org-fixture", model.organization.teamString("id"))
        assertEquals(0, writes)
    }
    @Test fun failedLaterPagesKeepLoadedMembersAndRetryTheSameCursor() = runTest {
        var later = 0
        val calls = TeamCalls(account()) { _, fields ->
            when (fields.teamString("operation")) {
                "organizations.get" -> buildJsonObject { put("organization", organization()) }
                "members.list" -> {
                    val offset = fields["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int
                    if (offset == 0) buildJsonObject { put("members", JsonArray(listOf(member("first", "member")))); put("nextOffset", 100) }
                    else {
                        assertEquals(100, offset)
                        if (++later == 1) throw java.io.IOException("Fictional page offline")
                        buildJsonObject { put("members", JsonArray(listOf(member("later", "member")))); put("nextOffset", JsonNull) }
                    }
                }
                else -> error("Unexpected fixture request")
            }
        }
        val model = TeamManagementModel(calls, organization())
        model.refresh("members"); model.refresh("members", true)
        assertEquals(listOf("first"), model.members.rows.map { it.teamString("id") }); assertEquals(100, model.members.next)
        model.refresh("members", true)
        assertEquals(listOf("first", "later"), model.members.rows.map { it.teamString("id") }); assertNull(model.members.next)
    }
    @Test fun nativeNameAndHandleValidationMatchesServiceLimits() {
        assertTrue(teamNameValid(" Fictional studio ")); assertFalse(teamNameValid(" ")); assertFalse(teamNameValid("x".repeat(81)))
        assertTrue(teamSlugValid("fictional-team")); assertFalse(teamSlugValid("double--dash")); assertFalse(teamSlugValid("12team"))
        assertTrue(teamHandleValid("@Example-Member")); assertFalse(teamHandleValid("https://fixture.invalid"))
        assertEquals("marta-studio", teamSuggestedSlug("Márta studio"))
    }
}
