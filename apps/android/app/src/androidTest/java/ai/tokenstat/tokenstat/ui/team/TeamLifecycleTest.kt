// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TeamLifecycleTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private class Fixture(var role: String = "owner", var active: Boolean = true, var joined: Boolean = true) {
        val writes = CopyOnWriteArrayList<JsonObject>()
        var revision = 7L
        var ownership: JsonObject? = null
        fun account() = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "self"); put("accountId", "self"); put("accountSession", "fixture-session") }
        fun organization() = buildJsonObject {
            put("id", "org-fixture"); put("name", "Fictional team"); put("ownerId", if (role == "owner") "self" else "previous")
            put("role", role); put("state", if (active) "active" else "paused"); put("eligible", active); put("revision", revision); put("membershipRevision", 12L)
        }
        fun request(from: String = "self", to: String = "next") = buildJsonObject { put("requestId", "ownership-fixture"); put("fromUserId", from); put("toUserId", to); put("revision", revision); put("current", true) }
        fun page(field: String, rows: List<JsonObject>) = buildJsonObject { put(field, JsonArray(rows)); put("nextOffset", JsonNull) }
        fun person(id: String, name: String, role: String) = buildJsonObject { put("id", id); put("name", name); put("role", role); put("revision", 1L); put("eligible", true); put("ownershipEligible", true) }
        fun call(method: String, body: JsonObject): JsonObject {
            if (method == "teams.capabilities") return buildJsonObject { put("enabled", true); put("ready", true); put("actorId", "self") }
            return when (body.teamString("operation")) {
                "organizations.list" -> page("organizations", if (joined) listOf(organization()) else emptyList())
                "organizations.get" -> buildJsonObject { put("organization", organization()); put("ownershipRequest", ownership ?: JsonNull) }
                "members.list" -> page("members", listOf(person("self", "Fictional self", role), person("next", "Fictional next owner", "member")))
                "repositories.list" -> page("repositories", listOf(buildJsonObject { put("id", "repo-fixture"); put("organizationId", "org-fixture"); put("name", "Fictional shared project"); put("role", "contributor"); put("revision", 1L) }))
                "checkouts.list" -> page("checkouts", emptyList())
                "inbox.list" -> page("invitations", listOf(buildJsonObject { put("id", "invitation-fixture"); put("organizationId", "org-fixture"); put("organizationName", "Fictional team"); put("role", "member") }))
                "inbox.get" -> buildJsonObject {
                    put("invitation", buildJsonObject { put("id", "invitation-fixture"); put("organizationId", "org-fixture"); put("organizationName", "Fictional team"); put("role", "member"); put("state", "pending") })
                    put("eligible", true); put("available", true)
                    put("repositoryAccess", JsonArray(listOf(buildJsonObject { put("repositoryId", "repo-fixture"); put("name", "Fictional shared project"); put("role", "contributor") })))
                }
                "inbox.accept" -> { writes += body; joined = true; buildJsonObject { put("joined", true); put("organizationId", "org-fixture") } }
                "ownership.request" -> { writes += body; revision++; ownership = request(); buildJsonObject {} }
                "ownership.cancel" -> { writes += body; revision++; ownership = null; buildJsonObject {} }
                "ownership.accept" -> { writes += body; revision++; role = "owner"; ownership = null; buildJsonObject {} }
                "organizations.delete", "members.remove" -> { writes += body; joined = false; buildJsonObject {} }
                else -> error("Unexpected fictional lifecycle request")
            }
        }
    }
    private fun show(fixture: Fixture) {
        compose.setContent {
            TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                Surface(Modifier.fillMaxSize().safeDrawingPadding()) { TeamScreen(fixture.account()) { method, body -> fixture.call(method, body) } }
            } }
        }
    }
    private fun ready(text: String) { compose.waitUntil(8_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() } }
    private fun button(text: String) = compose.onNode(hasText(text) and hasClickAction())
    private fun dialogButton(text: String) = compose.onNode(hasText(text) and hasClickAction() and hasAnyAncestor(isDialog()))
    private fun confirm() = compose.onNode(isToggleable() and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
    private fun management() { ready(L10n.text("common.teams.manage_teams")); button(L10n.text("common.teams.manage_teams")).performClick(); ready(L10n.text("common.settings")) }

    @Test fun inboxReviewsProjectAccessBeforeExplicitlyJoiningTheBoundAccount() {
        val fixture = Fixture(role = "member", joined = false); show(fixture)
        ready(L10n.text("common.teams.invitations_for_you")); button(L10n.text("common.teams.invitations_for_you")).performClick()
        ready(L10n.text("common.teams.review_invitation")); button(L10n.text("common.teams.review_invitation")).performClick()
        ready(L10n.text("common.teams.join_content_detail"))
        compose.onNodeWithText("Fictional shared project").assertIsDisplayed()
        compose.onNodeWithText(L10n.text("common.teams.execution_separate")).assertIsDisplayed()
        assertEquals(0, fixture.writes.size)
        dialogButton(L10n.text("common.teams.join_organization")).assertIsEnabled().performClick()
        ready(L10n.text("common.teams.manage_teams"))
        assertEquals(1, fixture.writes.size)
        assertEquals("invitation-fixture", fixture.writes.single().teamString("invitation"))
        assertEquals("fixture-session", fixture.writes.single().teamString("_accountSession")); assertFalse(fixture.writes.single().containsKey("page"))
    }
    @Test fun pausedOwnerCanRequestCancelAndDeleteWithSeparateReviewedConfirmations() {
        val fixture = Fixture(active = false); show(fixture); management()
        compose.onAllNodesWithText(L10n.text("common.teams.invite_member")).assertCountEquals(0)
        button(L10n.text("common.settings")).performClick()
        ready(L10n.text("common.teams.transfer_ownership")); button(L10n.text("common.teams.transfer_ownership")).performClick()
        dialogButton(L10n.text("common.teams.send_ownership_request")).assertIsNotEnabled()
        dialogButton(L10n.text("common.teams.choose_member")).performClick()
        button("Fictional next owner").performClick(); confirm()
        dialogButton(L10n.text("common.teams.send_ownership_request")).assertIsEnabled().performClick()
        ready(L10n.text("common.teams.cancel_ownership_request")); button(L10n.text("common.teams.cancel_ownership_request")).performClick()
        dialogButton(L10n.text("common.teams.cancel_ownership_request")).assertIsNotEnabled()
        confirm(); dialogButton(L10n.text("common.teams.cancel_ownership_request")).performClick()
        compose.waitUntil(8_000) { fixture.writes.size == 2 && compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty() }
        val cancellation = fixture.writes.last()["input"]!!.jsonObject
        assertEquals("ownership-fixture", cancellation.teamString("requestId")); assertEquals(8L, cancellation["expectedRevision"]!!.jsonPrimitive.long)
        button(L10n.text("common.teams.delete_organization")).performClick()
        dialogButton(L10n.text("common.teams.delete_organization")).assertIsNotEnabled()
        compose.onNodeWithTag("team.organization.delete_confirmation").performTextInput("Wrong name")
        dialogButton(L10n.text("common.teams.delete_organization")).assertIsNotEnabled()
        compose.onNodeWithTag("team.organization.delete_confirmation").performTextReplacement("Fictional team")
        dialogButton(L10n.text("common.teams.delete_organization")).assertIsEnabled().performClick()
        ready(L10n.text("common.teams.no_organizations"))
        assertEquals(3, fixture.writes.size)
        assertEquals(9L, fixture.writes.last()["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        assertEquals("Fictional team", fixture.writes.last()["input"]!!.jsonObject.teamString("confirmName"))
    }
    @Test fun inactiveMemberCanLeaveOnlyTheirOwnMembership() {
        val fixture = Fixture(role = "member", active = false); show(fixture); management()
        button(L10n.text("common.settings")).performClick()
        ready(L10n.text("common.teams.leave_organization"))
        compose.onAllNodesWithText(L10n.text("common.teams.transfer_ownership")).assertCountEquals(0)
        compose.onAllNodesWithText(L10n.text("common.teams.delete_organization")).assertCountEquals(0)
        button(L10n.text("common.teams.leave_organization")).performClick()
        dialogButton(L10n.text("common.teams.leave_organization")).assertIsNotEnabled()
        confirm(); dialogButton(L10n.text("common.teams.leave_organization")).performClick()
        ready(L10n.text("common.teams.no_organizations"))
        assertEquals("self", fixture.writes.single().teamString("user")); assertEquals(12L, fixture.writes.single()["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
    }
    @Test fun onlyTheReviewedRecipientCanAcceptTheCurrentOwnershipRequest() {
        val fixture = Fixture(role = "member"); fixture.ownership = fixture.request(from = "previous", to = "self")
        show(fixture); management()
        ready(L10n.text("common.teams.review_ownership")); button(L10n.text("common.teams.review_ownership")).performClick()
        dialogButton(L10n.text("common.teams.accept_ownership")).assertIsNotEnabled()
        compose.onNodeWithText(L10n.text("common.teams.accept_ownership_confirmation")).assertIsDisplayed()
        confirm(); dialogButton(L10n.text("common.teams.accept_ownership")).performClick()
        ready(L10n.text("common.teams.invite_member"))
        assertEquals("ownership.accept", fixture.writes.single().teamString("operation"))
        assertEquals("ownership-fixture", fixture.writes.single()["input"]!!.jsonObject.teamString("requestId"))
        assertEquals(7L, fixture.writes.single()["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
    }
}
