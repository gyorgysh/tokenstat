// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TeamLifecycleModelTest {
    private fun account() = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "self"); put("accountId", "self"); put("accountSession", "fixture-session") }
    private fun org(role: String, revision: Long = 7, membership: Long = 12) = buildJsonObject {
        put("id", "org-fixture"); put("ownerId", if (role == "owner") "self" else "previous"); put("name", "Fictional team")
        put("role", role); put("state", "paused"); put("eligible", false); put("revision", revision); put("membershipRevision", membership)
    }
    private fun successor(eligible: Boolean = true) = buildJsonObject { put("id", "next"); put("name", "Fictional next owner"); put("ownershipEligible", eligible) }
    private fun request(id: String = "ownership-fixture", current: Boolean = true, to: String = "self", from: String = "previous", revision: Long = 9) = buildJsonObject {
        put("requestId", id); put("fromUserId", from); put("toUserId", to); put("current", current); put("revision", revision)
    }
    private fun refuses(action: () -> Unit) = assertTrue(runCatching(action).isFailure)
    @Test fun pausedOwnerCanRecoverWithoutEnablingCollaborationOrRetargetingAReview() = runTest {
        var revision = 7L; val writes = mutableListOf<JsonObject>()
        val calls = TeamCalls(account()) { _, body -> when (body.teamString("operation")) {
            "organizations.get" -> buildJsonObject { put("organization", org("owner", revision)) }
            "members.list" -> buildJsonObject { put("members", JsonArray(listOf(successor()))); put("nextOffset", JsonNull) }
            else -> { writes += body; buildJsonObject {} }
        } }
        val model = TeamManagementModel(calls, org("owner"))
        model.refresh("members")
        assertFalse(model.active); assertFalse(model.manager); assertTrue(model.currentOwner)
        val reviewed = model.organization
        refuses { model.deleteOrganization("Wrong name", reviewed) }
        refuses { model.leave(reviewed) }
        refuses { model.transfer(successor(false), reviewed) }
        assertEquals("Fictional team", model.deleteOrganization("Fictional team", reviewed).teamString("confirmName"))
        val transfer = model.transfer(successor(), reviewed)
        model.mutate("ownership.request", transfer)
        assertEquals("next", writes.single()["input"]!!.jsonObject.teamString("userId"))
        assertEquals(7L, writes.single()["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        assertFalse(writes.single().containsKey("page")); assertEquals("fixture-session", writes.single().teamString("_accountSession"))
        revision = 8; model.refresh("settings")
        refuses { model.transfer(successor(), reviewed) }
        refuses { model.deleteOrganization("Fictional team", reviewed) }
    }
    @Test fun inactiveMemberCanLeaveOnlyTheirOwnReviewedMembership() = runTest {
        var membership = 12L; val writes = mutableListOf<JsonObject>()
        val calls = TeamCalls(account()) { _, body -> when (body.teamString("operation")) {
            "organizations.get" -> buildJsonObject { put("organization", org("member", membership = membership)) }
            else -> { writes += body; buildJsonObject {} }
        } }
        val model = TeamManagementModel(calls, org("member")); model.refresh("settings")
        val reviewed = model.organization
        model.mutate("members.remove", model.leave(reviewed), user = "self")
        assertEquals("self", writes.single().teamString("user")); assertEquals(12L, writes.single()["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        refuses { model.deleteOrganization("Fictional team", reviewed) }
        assertTrue(runCatching { model.mutate("members.remove", buildJsonObject {}, user = "another-person") }.isFailure)
        assertEquals(1, writes.size)
        membership = 13; model.refresh("settings"); refuses { model.leave(reviewed) }
    }
    @Test fun ownershipAcceptAndCancelKeepTheOriginalRequestAndRecipient() = runTest {
        var current = request()
        val calls = TeamCalls(account()) { _, _ -> buildJsonObject { put("organization", org("member")); put("ownershipRequest", current) } }
        val model = TeamManagementModel(calls, org("member")); model.refresh("settings")
        val reviewed = model.ownershipRequest!!
        assertEquals("ownership-fixture", model.ownershipDecision(reviewed, false).teamString("requestId"))
        refuses { model.ownershipDecision(reviewed, true) }
        current = request(id = "replacement", revision = 10); model.refresh("settings")
        refuses { model.ownershipDecision(reviewed, false) }
        current = request(current = false); model.refresh("settings")
        refuses { model.ownershipDecision(model.ownershipRequest!!, false) }
        current = request(to = "another-person"); model.refresh("settings")
        refuses { model.ownershipDecision(model.ownershipRequest!!, false) }
        val ownerCalls = TeamCalls(account()) { _, _ -> buildJsonObject { put("organization", org("owner")); put("ownershipRequest", request(from = "self", to = "next", current = false)) } }
        val owner = TeamManagementModel(ownerCalls, org("owner")); owner.refresh("settings")
        assertEquals(9L, owner.ownershipDecision(owner.ownershipRequest!!, true)["expectedRevision"]!!.jsonPrimitive.long)
    }
}
