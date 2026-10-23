// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class TeamProjectsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun row(id: String, name: String, org: String? = null) = buildJsonObject {
        put("id", id); put("name", name); org?.let { put("organizationId", it); put("role", "viewer") }
    }
    private fun page(field: String, rows: List<JsonObject>, next: Int? = null) = buildJsonObject {
        put(field, JsonArray(rows)); put("nextOffset", next?.let(::JsonPrimitive) ?: JsonNull)
    }
    @Test fun findsIncomingProjectsBeyondTheSelectedTeamAndReturnsFromAllTeammates() {
        val observed = CopyOnWriteArrayList<JsonObject>(); var fail = true
        val account = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "fictional"); put("accountId", "person"); put("accountSession", "session") }
        val request: suspend (String, JsonObject) -> JsonElement = { method, fields ->
            assertEquals("session", fields.teamString("_accountSession"))
            if (method == "teams.capabilities") buildJsonObject { put("enabled", true); put("ready", true); put("actorId", "person") }
            else {
                assertEquals("teams.directory", method); observed += fields
                val offset = fields["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int
                when (fields.teamString("operation")) {
                    "organizations.list" -> if (offset == 0) page("organizations", listOf(row("first", "First fictional team")), 100)
                        else page("organizations", listOf(row("later", "Later fictional team")))
                    "repositories.list" -> if (fields.teamString("organization") == "first") page("repositories", emptyList())
                        else if (offset == 0) page("repositories", listOf(row("one", "First shared project", "later")), 100)
                        else if (fail) { fail = false; error("Fictional project page outage") }
                        else page("repositories", listOf(row("two", "Later shared project", "later")))
                    "checkouts.list" -> page("checkouts", emptyList())
                    else -> error("Unexpected native project request")
                }
            }
        }
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) { TeamScreen(account, request) }
                }
            }
        }
        val shared = L10n.text("common.teams.shared_projects")
        compose.waitUntil(5_000) { compose.onAllNodesWithText(shared).fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText(shared).performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText(L10n.text("common.teams.more_organizations")))
        compose.onNodeWithText(L10n.text("common.teams.more_organizations")).performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("Later fictional team"))
        compose.waitUntil(5_000) { observed.any { it.teamString("operation") == "repositories.list" && it.teamString("organization") == "later" } }
        compose.onNode(hasScrollAction()).performScrollToNode(hasText(L10n.text("common.teams.load_more")))
        compose.onNodeWithText(L10n.text("common.teams.load_more")).performClick()
        compose.waitForIdle()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("First shared project"))
        compose.onNodeWithText("First shared project").assertExists()
        compose.onNode(hasScrollAction()).performScrollToNode(hasText(L10n.text("common.retry")))
        compose.onNodeWithText(L10n.text("common.retry")).performClick()
        val project = "team.project.later.two"
        compose.onNode(hasScrollAction()).performScrollToNode(hasTestTag(project))
        compose.onNode(hasText(L10n.text("common.teams.open_shared_project")) and hasAnyAncestor(hasTestTag(project))).performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText(L10n.text("common.teams.all_teammates")).fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText(L10n.text("common.teams.all_teammates")).assertExists()
        compose.onNodeWithText(shared).performClick()
        compose.onNode(hasScrollAction()).performScrollToNode(hasTestTag(project))
        compose.onNodeWithText("Later shared project").assertExists()
        assertEquals(listOf(0, 100, 100), observed.filter { it.teamString("operation") == "repositories.list" && it.teamString("organization") == "later" }
            .map { it["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int })
    }
}
