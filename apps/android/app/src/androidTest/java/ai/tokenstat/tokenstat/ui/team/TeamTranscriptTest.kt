// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import ai.tokenstat.tokenstat.ui.workspace.ChartWebSurface
import ai.tokenstat.tokenstat.core.CoreFailure
import android.view.View
import android.view.ViewGroup
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
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TeamTranscriptTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun knownStopSurvivesAHistoryReadFailure() {
        val account = buildJsonObject { put("signedIn", true); put("host", "https://fixture.invalid"); put("handle", "fixture"); put("accountId", "person-fixture"); put("accountSession", "fictional-session") }
        val target = buildJsonObject { put("organization", "org-fixture"); put("repository", "repo-fixture"); put("checkout", "checkout-fixture"); put("share", "share-fixture") }
        val fence = buildJsonObject { put("fixture", "exact-original-fence") }
        var failed = false
        var stopped: JsonElement? = null
        val calls = TeamCalls(account) { method, body ->
            when (body["method"]?.jsonPrimitive?.content) {
                "team.chat.details" -> {
                    if (failed) throw CoreFailure("invalid_response", "Fictional history read failure")
                    buildJsonObject { put("chat", buildJsonObject { put("id", "share-fixture"); put("checkoutId", "checkout-fixture"); put("backend", "claude"); put("allowsAgentRuns", true) }) }
                }
                "team.chat.events" -> buildJsonObject { put("shareId", "share-fixture"); put("events", JsonArray(emptyList())); put("hasMore", false) }
                "team.chat.ask.review" -> buildJsonObject { put("agentRuns", true); put("review", "fictional-review") }
                "team.chat.ask" -> buildJsonObject { put("state", "running"); put("fence", fence) }
                "team.chat.ask.status" -> buildJsonObject { put("running", true) }
                "team.chat.ask.stop" -> { stopped = body["params"]!!.jsonObject["fence"]; buildJsonObject {} }
                else -> error("Unexpected fictional call: $method")
            }
        }
        val folder = java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "team-stop-${java.util.UUID.randomUUID()}")
        try {
            compose.setContent {
                TsTheme(DarkColors) {
                    MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                        Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                            TeamChatReader(calls, ChatTarget(target, "Fictional chat", "Fictional computer", "fictional-host"), TeamCommentDraftStore(folder)) {}
                        }
                    }
                }
            }
            compose.waitUntil(5_000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(hasSetTextAction()).performTextInput("Fictional question")
            compose.onNodeWithText(L10n.text("common.teams.ask"), useUnmergedTree = true).performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithText(L10n.text("common.teams.stop_agent")).fetchSemanticsNodes().isNotEmpty() }
            compose.runOnIdle { failed = true }
            compose.onNodeWithText(L10n.text("common.refresh")).performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Fictional history read failure").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(L10n.text("common.teams.stop_agent")).assertIsDisplayed().performClick()
            compose.runOnIdle { assertEquals(fence, stopped) }
        } finally { folder.deleteRecursively() }
    }
    @Test fun coalescedSharedChartAndToolDetailsUseTheReadOnlyReader() {
        val spec = """{"version":1,"type":"bar","title":"Fictional shared chart","categories":["A","B"],"series":[{"name":"Fictional values","data":[1,2]}]}"""
        val source = "```tokenstat-chart\n$spec\n```"
        fun event(seq: Int, body: JsonObject) = buildJsonObject {
            put("seq", seq); put("kind", "agent"); put("backend", "claude"); put("mode", "agent"); put("event", body)
            put("author", buildJsonObject {
                put("kind", "agent"); put("backend", "claude"); put("runId", "run_" + "a".repeat(32))
                put("initiatedBy", buildJsonObject { put("kind", "person"); put("id", "person-fixture"); put("name", "Fictional teammate") })
            })
        }
        fun text(value: String) = buildJsonObject { put("kind", "text"); put("delta", value) }
        val blocks = TeamTranscript.project(listOf(event(0, text(source.take(25))), event(1, text(source.drop(25))),
            event(2, buildJsonObject { put("kind", "toolStart"); put("callId", "fictional-call"); put("verb", "Read"); put("target", "fictional.txt"); put("input", buildJsonObject {}) }),
            event(3, buildJsonObject { put("kind", "toolEnd"); put("callId", "fictional-call"); put("ok", true); put("detail", "Fictional tool detail") })), "claude")
        var fetches = 0
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize()) {
                        Column(Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(12.dp)) {
                            blocks.forEach { block -> TeamTranscriptRow(block) { fetches++; error("unexpected attachment") } }
                        }
                    }
                }
            }
        }
        fun find(view: View): ChartWebSurface? = if (view is ChartWebSurface) view else if (view is ViewGroup)
            (0 until view.childCount).firstNotNullOfOrNull { find(view.getChildAt(it)) } else null
        lateinit var web: ChartWebSurface
        compose.waitUntil(10_000) {
            var found: ChartWebSurface? = null
            InstrumentationRegistry.getInstrumentation().runOnMainSync { found = find(compose.activity.window.decorView) }
            found?.also { web = it } != null
        }
        fun js(script: String): String {
            val result = AtomicReference(""); val done = CountDownLatch(1)
            InstrumentationRegistry.getInstrumentation().runOnMainSync { web.evaluateJavascript(script) { result.set(it); done.countDown() } }
            assertTrue(done.await(10, TimeUnit.SECONDS)); return result.get()
        }
        compose.waitUntil(20_000) { js("!!window.TokenstatChart?.inspect().valid") == "true" }
        assertEquals("true", js("document.querySelectorAll('#plot svg path').length>0"))
        compose.onAllNodesWithText(L10n.text("common.teams.agent_asked_by", "Claude Code", "Fictional teammate")).assertCountEquals(2)
        val tool = L10n.text("common.teams.tool_output") + " · Read fictional.txt"
        compose.onNodeWithText(tool).performScrollTo().performClick()
        compose.onNodeWithText("{}\n\nFictional tool detail").performScrollTo().assertIsDisplayed()
        assertEquals(0, fetches)
        compose.onAllNodesWithText(L10n.text("common.teams.ask")).assertCountEquals(0)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: error("no screenshot")
        val resolver = instrumentation.targetContext.contentResolver
        val image = resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "teams-shared-tool.png")
            put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-teams-qa")
        }) ?: error("cannot save fictional screenshot")
        resolver.openOutputStream(image)!!.use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
}
