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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class TeamDirectoryTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun account(person: String) = buildJsonObject {
        put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", person)
        put("accountId", person); put("accountSession", "session-$person")
    }
    private fun row(id: String, name: String, organization: String? = null) = buildJsonObject {
        put("id", id); put("name", name)
        if (organization != null) { put("organizationId", organization); put("role", "viewer") }
    }
    private fun page(field: String, rows: List<JsonObject>, next: Int? = null) = buildJsonObject {
        put(field, JsonArray(rows)); next?.let { put("nextOffset", it) }
    }
    private fun capabilities(person: String) = buildJsonObject { put("enabled", true); put("ready", true); put("actorId", person) }
    private fun screen(account: JsonObject, request: suspend (String, JsonObject) -> JsonElement) {
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) { TeamScreen(account, request) }
                }
            }
        }
    }
    @Test fun laterTeamsAndProjectsRemainReachableAfterAnOfflinePage() {
        val observed = CopyOnWriteArrayList<JsonObject>()
        var failPage = true
        screen(account("person-one")) { method, body ->
            if (method == "teams.capabilities") capabilities("person-one") else {
                assertEquals("teams.directory", method); observed += body
                val offset = body["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int
                when (body["operation"]!!.jsonPrimitive.content) {
                    "organizations.list" -> if (offset == 0) page("organizations", listOf(row("org-first", "First team")), 100)
                        else if (failPage) { failPage = false; error("Fictional temporary outage") }
                        else page("organizations", listOf(row("org-later", "Later team")))
                    "repositories.list" -> if (body["organization"]!!.jsonPrimitive.content == "org-first") page("repositories", emptyList())
                        else if (offset == 0) page("repositories", listOf(row("repo-first", "First project", "org-later")), 100)
                        else page("repositories", listOf(row("repo-later", "Later project", "org-later")))
                    "checkouts.list" -> page("checkouts", emptyList())
                    else -> error("Unexpected fictional directory operation")
                }
            }
        }
        compose.waitUntil(5_000) { compose.onAllNodesWithText("First team").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText("First team").performClick()
        compose.onNodeWithText(L10n.text("common.teams.organizations")).assertExists().performClick()
        val moreTeams = L10n.text("common.teams.more_organizations")
        compose.onNodeWithText(moreTeams).performClick()
        compose.waitForIdle(); compose.onNodeWithText("First team").assertExists()
        compose.onNodeWithText(moreTeams).assertIsEnabled().performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Later team").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText("Later team").performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("First project").fetchSemanticsNodes().size == 1 }
        compose.onNode(hasScrollAction()).performScrollToNode(hasText(L10n.text("common.teams.load_more")))
        compose.onNodeWithText(L10n.text("common.teams.load_more")).performClick()
        compose.waitUntil(5_000) { observed.any { it["operation"]?.jsonPrimitive?.content == "repositories.list" && it["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int == 100 } }
        compose.onNode(hasScrollAction()).performScrollToNode(hasText("Later project"))
        compose.onNodeWithText("Later project").assertExists()
        assertTrue(observed.all { it["_accountSession"]?.jsonPrimitive?.content == "session-person-one" })
        assertTrue(observed.filter { it["operation"]?.jsonPrimitive?.content == "repositories.list" && it["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int == 100 }
            .all { it["organization"]?.jsonPrimitive?.content == "org-later" })
    }
    @Test fun anOldAccountPageCannotAppearAfterSwitchingAccounts() {
        val current = mutableStateOf(account("person-one"))
        val entered = CompletableDeferred<Unit>(); val response = CompletableDeferred<JsonObject>()
        val request: suspend (String, JsonObject) -> JsonElement = { method, body ->
            val person = body["_accountSession"]!!.jsonPrimitive.content.removePrefix("session-")
            if (method == "teams.capabilities") capabilities(person) else {
                assertEquals("organizations.list", body["operation"]!!.jsonPrimitive.content)
                val offset = body["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int
                if (person == "person-one" && offset > 0) { entered.complete(Unit); response.await() }
                else page("organizations", listOf(row("org-same", "Team for $person")), 100)
            }
        }
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) { TeamScreen(current.value, request) }
                }
            }
        }
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Team for person-one").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText(L10n.text("common.teams.more_organizations")).performClick()
        compose.waitUntil(5_000) { entered.isCompleted }
        compose.runOnIdle { current.value = account("person-two") }
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Team for person-two").fetchSemanticsNodes().size == 1 }
        response.complete(page("organizations", listOf(row("org-old", "Old account result"))))
        compose.waitForIdle()
        compose.onNodeWithText("Old account result").assertDoesNotExist()
        compose.onNodeWithText("Team for person-one").assertDoesNotExist()
        compose.onNodeWithText("Team for person-two").assertExists()
    }
}
