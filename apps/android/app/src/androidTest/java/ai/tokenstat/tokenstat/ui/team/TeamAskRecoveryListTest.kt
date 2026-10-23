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
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class TeamAskRecoveryListTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun unreachableProjectsKeepTheOriginalRequestAndStopAndNeverCrossAccounts() {
        val root = java.io.File(compose.activity.cacheDir, "ask-list-" + UUID.randomUUID())
        val storage = TeamAskRecoveryStore(root)
        val target = TeamCommentTarget("https://fixture.invalid", "person-one", "org", "repo", "checkout", "share", "a".repeat(64))
        val input = buildJsonObject { put("text", "Fictional saved request"); put("review", "c".repeat(64)); put("clientMessageId", UUID.randomUUID().toString()); put("clientMessageCreatedAtMs", 1) }
        val fence = buildJsonObject { put("runId", "run_" + "a".repeat(32)); put("incarnation", "b".repeat(64)) }
        storage.replace(target, TeamAskRecord(input), null, "Fictional unreachable project")
        val observed = CopyOnWriteArrayList<JsonObject>(); val person = mutableStateOf("person-one")
        fun calls(who: String) = TeamCalls(buildJsonObject { put("signedIn", true); put("host", target.origin); put("handle", who); put("accountId", who); put("accountSession", "session-$who") }) { method, body ->
            assertEquals("teams.ask", method); assertEquals(JsonPrimitive("session-person-one"), body["_accountSession"])
            assertEquals(JsonPrimitive(target.share), body["target"]!!.jsonObject["share"]); observed += body
            when (body["method"]!!.jsonPrimitive.content) {
                "team.chat.ask" -> { assertEquals(input, body["params"]); buildJsonObject { put("state", "running"); put("fence", fence) } }
                "team.chat.ask.stop" -> { assertEquals(fence, body["params"]!!.jsonObject["fence"]); buildJsonObject { put("stopping", false) } }
                "team.chat.ask.status" -> { assertEquals(fence, body["params"]!!.jsonObject["fence"]); throw java.io.IOException("Fictional computer offline") }
                else -> error("Recovery attempted a new review or directory read")
            }
        }
        try {
            compose.setContent { TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) { Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                key(person.value) { val api = remember { calls(person.value) }; TeamAskRecoveryList(storage, api, {}) }
            } } } }
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Fictional saved request").fetchSemanticsNodes().isNotEmpty() }
            assertTrue(observed.isEmpty())
            compose.onNodeWithText(L10n.text("common.teams.recover_ask")).performScrollTo().performClick()
            compose.onNodeWithText(L10n.text("common.teams.retry_same_ask")).performScrollTo().performClick()
            compose.waitUntil(5_000) { storage.load(target)?.record?.fence == fence }
            compose.onNodeWithText(L10n.text("common.teams.stop_agent")).performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(5_000) { observed.size == 2 }
            assertEquals(input, storage.load(target)!!.record.input)
            compose.runOnIdle { person.value = "person-two" }
            compose.waitUntil(5_000) { compose.onAllNodesWithText(L10n.text("common.teams.no_saved_asks")).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Fictional saved request").assertDoesNotExist(); assertEquals(2, observed.size)
            assertEquals(fence, storage.load(target)!!.record.fence)
        } finally { root.deleteRecursively() }
    }
}
