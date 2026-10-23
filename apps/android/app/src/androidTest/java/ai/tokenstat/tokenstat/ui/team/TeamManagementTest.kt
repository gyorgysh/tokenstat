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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TeamManagementTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun account(person: String = "self", session: String = "fixture-session") = buildJsonObject {
        put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", person); put("accountId", person); put("accountSession", session)
    }
    private fun org() = buildJsonObject { put("id", "org-fixture"); put("name", "Fictional team"); put("ownerId", "self"); put("role", "owner"); put("state", "active"); put("eligible", true); put("revision", 7L) }
    private fun person(id: String, name: String, role: String, revision: Long) = buildJsonObject {
        put("id", id); put("name", name); put("role", role); put("revision", revision); put("eligible", true)
    }
    private fun page(field: String, rows: List<JsonObject>) = buildJsonObject { put(field, JsonArray(rows)); put("nextOffset", JsonNull) }
    private fun show(account: () -> JsonObject, bridge: suspend (String, JsonObject) -> JsonElement) {
        compose.setContent {
            TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                Surface(Modifier.fillMaxSize().safeDrawingPadding()) { TeamScreen(account(), bridge) }
            } }
        }
    }
    private fun ready(text: String) { compose.waitUntil(8_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() } }
    private fun button(text: String) = compose.onNode(hasText(text) and hasClickAction())
    private fun dialogButton(text: String) = compose.onNode(hasText(text) and hasClickAction() and hasAnyAncestor(isDialog()))

    @Test fun nativeMemberRolesAndInvitationsReviewTheExactPersonAndAccess() {
        val writes = CopyOnWriteArrayList<JsonObject>()
        var guestRole = "member"; var guestRevision = 5L; var guestRemoved = false
        var repositoryRole: String? = null; var accessRevision = 0L
        show({ account() }) { method, fields ->
            if (method == "teams.capabilities") buildJsonObject { put("enabled", true); put("ready", true); put("actorId", "self") }
            else when (fields.teamString("operation")) {
                "organizations.list" -> page("organizations", listOf(org()))
                "organizations.get" -> buildJsonObject { put("organization", org()) }
                "repositories.list" -> page("repositories", listOf(buildJsonObject { put("id", "repo-fixture"); put("organizationId", "org-fixture"); put("name", "Fictional project"); put("role", "maintainer"); put("revision", 1L) }))
                "checkouts.list" -> page("checkouts", emptyList())
                "members.list" -> page("members", listOf(person("self", "Fictional owner", "owner", 2)) + if (guestRemoved) emptyList() else listOf(person("guest", "Fictional teammate", guestRole, guestRevision)))
                "members.role" -> {
                    writes += fields; guestRole = fields["input"]!!.jsonObject.teamString("role")!!; guestRevision++
                    buildJsonObject {}
                }
                "members.remove" -> { writes += fields; guestRemoved = true; buildJsonObject {} }
                "repositories.members" -> page("members", listOf(buildJsonObject { put("id", "guest"); put("name", "Fictional teammate"); put("role", repositoryRole?.let(::JsonPrimitive) ?: JsonNull); put("revision", accessRevision); put("eligible", true) }))
                "repositories.access" -> { writes += fields; repositoryRole = fields["input"]!!.jsonObject.teamString("role"); accessRevision++; buildJsonObject {} }
                "invitations.create" -> {
                    writes += fields
                    buildJsonObject { put("invitationURL", "https://fixture.invalid/invite/fictional-token") }
                }
                else -> error("Unexpected fictional management request")
            }
        }
        ready(L10n.text("common.teams.manage_teams")); button(L10n.text("common.teams.manage_teams")).performClick()
        ready("Fictional teammate")
        compose.onAllNodesWithText(L10n.text("common.teams.change_role")).assertCountEquals(1)
        button(L10n.text("common.teams.change_role")).performClick()
        dialogButton(L10n.text("common.save")).assertIsNotEnabled()
        dialogButton(L10n.text("common.teams.member")).performClick()
        button(L10n.text("common.teams.admin")).performClick()
        dialogButton(L10n.text("common.save")).assertIsEnabled().performClick()
        compose.waitUntil(8_000) { writes.size == 1 && compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty() }
        val change = writes.single()
        assertEquals("guest", change.teamString("user")); assertEquals("org-fixture", change.teamString("organization"))
        assertEquals(5L, change["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        assertEquals("fixture-session", change.teamString("_accountSession")); assertFalse(change.containsKey("page"))
        button(L10n.text("common.teams.remove_member")).performClick()
        dialogButton(L10n.text("common.cancel")).performClick()
        assertEquals(1, writes.size)
        button(L10n.text("common.teams.invite_member")).performClick()
        ready(L10n.text("common.teams.tokenstat_handle"))
        dialogButton(L10n.text("common.teams.invite_member")).assertIsNotEnabled()
        compose.onNode(hasSetTextAction()).performTextInput("@new-teammate")
        dialogButton(L10n.text("common.teams.invite_member")).assertIsEnabled().performClick()
        ready(L10n.text("common.teams.invitation_ready"))
        val invitation = writes.last()["input"]!!.jsonObject
        assertEquals("new-teammate", invitation.teamString("handle")); assertEquals("member", invitation.teamString("role"))
        assertEquals(JsonArray(emptyList()), invitation["assignments"])
        assertFalse(invitation.containsKey("allowAgentRuns"))
        dialogButton(L10n.text("common.done")).performClick()
        button(L10n.text("common.teams.repositories")).performClick()
        ready(L10n.text("common.teams.repository_access")); button(L10n.text("common.teams.repository_access")).performClick()
        ready(L10n.text("common.teams.manage_access")); button(L10n.text("common.teams.manage_access")).performClick()
        dialogButton(L10n.text("common.save")).assertIsNotEnabled()
        dialogButton(L10n.text("common.teams.no_access")).performClick()
        button(L10n.text("common.teams.contributor")).performClick()
        dialogButton(L10n.text("common.save")).assertIsEnabled().performClick()
        compose.waitUntil(8_000) { writes.size == 3 && compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty() }
        val access = writes.last()
        assertEquals("repositories.access", access.teamString("operation")); assertEquals("repo-fixture", access.teamString("repository"))
        assertEquals("guest", access.teamString("user")); assertEquals(0L, access["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        button(L10n.text("common.back")).performClick(); button(L10n.text("common.teams.members")).performClick()
        ready(L10n.text("common.teams.remove_member")); button(L10n.text("common.teams.remove_member")).performClick()
        dialogButton(L10n.text("common.teams.remove_member")).performClick()
        compose.waitUntil(8_000) { writes.size == 4 && compose.onAllNodesWithText("Fictional teammate").fetchSemanticsNodes().isEmpty() }
        val removal = writes.last()
        assertEquals("members.remove", removal.teamString("operation")); assertEquals("guest", removal.teamString("user"))
        assertEquals(6L, removal["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
    }

    @Test fun nativeCreationAndRenameKeepTheReviewedOrganizationRevision() {
        val writes = CopyOnWriteArrayList<JsonObject>()
        var created: JsonObject? = null
        show({ account() }) { method, fields ->
            if (method == "teams.capabilities") buildJsonObject { put("enabled", true); put("ready", true); put("actorId", "self") }
            else when (fields.teamString("operation")) {
                "organizations.list" -> page("organizations", listOfNotNull(created))
                "organizations.create" -> {
                    writes += fields
                    created = buildJsonObject { put("id", "org-created"); put("ownerId", "self"); put("name", fields["input"]!!.jsonObject.teamString("name")); put("role", "owner"); put("revision", 1L); put("state", "active"); put("eligible", true) }
                    buildJsonObject { put("organization", created!!) }
                }
                "organizations.get" -> buildJsonObject { put("organization", created!!) }
                "organizations.rename" -> {
                    writes += fields
                    created = JsonObject(created!! + mapOf("name" to fields["input"]!!.jsonObject["name"]!!, "revision" to JsonPrimitive(2L)))
                    buildJsonObject { put("organization", created!!) }
                }
                "members.list" -> page("members", listOf(person("self", "Fictional owner", "owner", 1)))
                "repositories.list" -> page("repositories", emptyList())
                else -> error("Unexpected fictional organization request")
            }
        }
        ready(L10n.text("common.teams.create_organization")); button(L10n.text("common.teams.create_organization")).performClick()
        dialogButton(L10n.text("common.teams.create_organization")).assertIsNotEnabled()
        compose.onNodeWithTag("team.management.name").performTextInput("Fictional studio")
        compose.onNodeWithTag("team.management.slug").assertTextContains("fictional-studio")
        dialogButton(L10n.text("common.teams.create_organization")).assertIsEnabled().performClick()
        ready(L10n.text("common.teams.manage_teams")); button(L10n.text("common.teams.manage_teams")).performClick()
        ready(L10n.text("common.teams.rename_organization")); button(L10n.text("common.teams.rename_organization")).performClick()
        dialogButton(L10n.text("common.save")).assertIsNotEnabled()
        compose.onNodeWithTag("team.management.name").performTextReplacement("Renamed fictional studio")
        dialogButton(L10n.text("common.save")).assertIsEnabled().performClick()
        ready("Renamed fictional studio")
        assertEquals(2, writes.size)
        assertEquals("fictional-studio", writes.first()["input"]!!.jsonObject.teamString("slug"))
        assertEquals("org-created", writes.last().teamString("organization")); assertEquals(1L, writes.last()["input"]!!.jsonObject["expectedRevision"]!!.jsonPrimitive.long)
        assertFalse(writes.first().containsKey("page")); assertFalse(writes.last().containsKey("page"))
    }

    @Test fun aLateManagementResponseCannotCrossAnAccountSwitch() {
        val current = mutableStateOf(account())
        val waiting = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        show({ current.value }) { method, fields ->
            val first = fields.teamString("_accountSession") == "fixture-session"
            if (method == "teams.capabilities") buildJsonObject { put("enabled", true); put("ready", true); put("actorId", if (first) "self" else "second") }
            else when (fields.teamString("operation")) {
                "organizations.list" -> page("organizations", if (first) listOf(org()) else emptyList())
                "organizations.get" -> buildJsonObject { put("organization", org()) }
                "repositories.list" -> page("repositories", emptyList())
                "members.list" -> withContext(NonCancellable) { waiting.complete(Unit); release.await(); page("members", listOf(person("late", "Old account private teammate", "member", 1))) }
                else -> error("Unexpected fictional management request")
            }
        }
        ready(L10n.text("common.teams.manage_teams")); button(L10n.text("common.teams.manage_teams")).performClick()
        compose.waitUntil(8_000) { waiting.isCompleted }
        compose.runOnIdle { current.value = account("second", "second-session") }
        ready(L10n.text("common.teams.no_organizations"))
        compose.runOnIdle { release.complete(Unit) }
        compose.waitForIdle()
        compose.onAllNodesWithText("Old account private teammate").assertCountEquals(0)
        compose.onAllNodesWithText(L10n.text("common.teams.change_role")).assertCountEquals(0)
    }
}
