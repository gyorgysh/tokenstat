// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TeamBrowserTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun publisherBackendsDriveCreationAndCatalogRefreshPreservesUncertainDrafts() {
        val ids = listOf("claude", "codex", "muse", "grok", "cursor", "agy", "opencode", "opencode2")
        val attempts = CopyOnWriteArrayList<JsonObject>()
        var advertise = true
        val account = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "fixture"); put("accountId", "person"); put("accountSession", "backend-session") }
        val calls = TeamCalls(account) { method, body ->
            assertEquals("backend-session", body["_accountSession"]?.jsonPrimitive?.content)
            when {
                method == "teams.directory" -> buildJsonObject { put("checkouts", JsonArray(listOf(buildJsonObject {
                    put("id", "computer"); put("deviceName", "Publishing computer"); put("hostKey", "fictional-host")
                }))) }
                method == "teams.connection.call" && body["method"]?.jsonPrimitive?.content == "team.lanes" -> buildJsonObject { put("lanes", JsonArray(emptyList())) }
                method == "teams.connection.call" && body["method"]?.jsonPrimitive?.content == "team.chat.catalog" -> buildJsonObject {
                    put("shares", JsonArray(emptyList()))
                    if (advertise) {
                        put("backends", JsonArray(ids.map { id -> buildJsonObject { put("id", id); put("label", "Publisher $id") } }))
                        put("nextCursor", "metadata-refresh")
                    }
                }
                method == "teams.ask" && body["method"]?.jsonPrimitive?.content == "team.chat.new" -> {
                    attempts += body["params"]!!.jsonObject
                    throw java.io.IOException("Fictional lost creation reply")
                }
                else -> error("Backend picker attempted local discovery or an unrelated call")
            }
        }
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                        Column(Modifier.verticalScroll(rememberScrollState()).padding(12.dp)) {
                            RepositoryCard(calls, "org", buildJsonObject { put("id", "repo"); put("name", "Fictional project"); put("role", "maintainer") }, onOpenChat = {})
                        }
                    }
                }
            }
        }
        val default = L10n.text("common.local_provider_use_default")
        compose.waitUntil(5_000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().size == 1 }
        compose.onNode(hasSetTextAction()).performScrollTo().performTextInput("Retained backend draft")
        fun send() {
            val before = attempts.size
            compose.onNodeWithText(L10n.text("common.teams.new_chat")).performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(5_000) { attempts.size == before + 1 }
            compose.waitForIdle()
            compose.onNode(hasSetTextAction()).assertTextContains("Retained backend draft")
        }
        var selected = default
        for (id in ids) {
            compose.onNodeWithText(selected).performScrollTo().performClick()
            compose.onNodeWithText("Publisher $id").performScrollTo().performClick()
            selected = "Publisher $id"
            send()
            assertEquals(id, attempts.last()["backend"]?.jsonPrimitive?.content)
        }
        val original = attempts.last()
        compose.runOnIdle { advertise = false }
        compose.onNodeWithText(L10n.text("common.teams.load_more")).performScrollTo().performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("opencode2").fetchSemanticsNodes().size == 1 }
        send()
        assertEquals(original, attempts.last())
        compose.onNodeWithText("opencode2").performScrollTo().performClick()
        ids.forEach { compose.onNodeWithText("Publisher $it").assertDoesNotExist() }
        compose.onNodeWithText(default).performClick()
        send()
        assertFalse(attempts.last().containsKey("backend"))
    }
    @Test fun laterComputersAndSharedChatsAreReachableThroughTheProductionBrowser() {
        val account = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "fixture"); put("accountId", "person-fixture"); put("accountSession", "fictional-session") }
        val observed = CopyOnWriteArrayList<Pair<String, JsonObject>>()
        var opened: ChatTarget? = null
        val calls = TeamCalls(account) { method, body ->
            observed += method to body
            if (method == "teams.directory") {
                val offset = body["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int
                buildJsonObject {
                    put("checkouts", JsonArray((if (offset == 0) 0..2 else 3..3).map { index -> buildJsonObject {
                        put("id", "computer-$index"); put("hostKey", "fictional-host-$index"); put("deviceName", "Fictional computer $index")
                    } }))
                    if (offset == 0) put("nextOffset", 3)
                }
            } else {
                assertEquals("teams.connection.call", method)
                val id = body["target"]!!.jsonObject["checkout"]!!.jsonPrimitive.content
                when (body["method"]!!.jsonPrimitive.content) {
                    "team.lanes" -> buildJsonObject { put("lanes", JsonArray(emptyList())) }
                    "team.chat.catalog" -> buildJsonObject {
                        val cursor = body["params"]!!.jsonObject["cursor"]?.jsonPrimitive?.content
                        val indexes = if (id != "computer-0") emptyList() else if (cursor == null) (0..49).toList() else listOf(50)
                        put("shares", JsonArray(indexes.map { index -> buildJsonObject {
                            put("id", "share-$index"); put("checkoutId", id); put("title", "Fictional chat $index")
                        } }))
                        if (id == "computer-0" && cursor == null) put("nextCursor", "v1:catalog:computer-0:50")
                    }
                    else -> error("unexpected fictional call")
                }
            }
        }
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                        Column(Modifier.verticalScroll(rememberScrollState()).padding(12.dp)) {
                            RepositoryCard(calls, "org-fixture", buildJsonObject { put("id", "repo-fixture"); put("name", "Fictional project"); put("role", "viewer") }, onOpenChat = { opened = it })
                        }
                    }
                }
            }
        }
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Fictional chat 0").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText(L10n.text("common.teams.load_more")).performScrollTo().performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Fictional chat 50").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText("Fictional chat 50").performScrollTo().performClick()
        screenshot("teams-browser-later-chat")
        compose.runOnIdle { assertEquals("share-50", opened?.target?.get("share")?.jsonPrimitive?.content) }
        compose.onNodeWithText(L10n.text("common.teams.load_more_computers")).performScrollTo().performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Fictional computer 3").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText("Fictional computer 3").performScrollTo().assertIsDisplayed()
        screenshot("teams-browser-later-computer")
        assertTrue(observed.any { (method, body) -> method == "teams.directory" && body["page"]!!.jsonObject["offset"]!!.jsonPrimitive.int == 3 })
        assertTrue(observed.any { (_, body) -> body["params"]?.jsonObject?.get("cursor")?.jsonPrimitive?.content == "v1:catalog:computer-0:50" })
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: error("no screenshot")
        val resolver = instrumentation.targetContext.contentResolver
        val image = resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-teams-qa")
        }) ?: error("cannot save fictional screenshot")
        resolver.openOutputStream(image)!!.use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }

}
