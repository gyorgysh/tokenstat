// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import android.graphics.Rect
import android.graphics.Bitmap
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class MobileChatSetupTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun json(value: String) = Json.parseToJsonElement(value).jsonObject
    private val chat = json("""{"id":"mobile-layout","backend":"codex","model":"gpt-6.1-sol","mode":"execute","autonomy":"bypass","running":false}""")
    private val reading = json("""{"source":"codex","plan":"Plus","observedAtMs":1793934000000,"windows":[{"label":"5-hour","percent":36},{"label":"weekly","percent":86,"resetsAtMs":1794460000000}]}""")
    @Composable private fun Screen(large: Boolean = false, width: Int = 320, content: @Composable () -> Unit) {
        DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(DpSize(width.dp, 740.dp))) {
            DeviceConfigurationOverride(DeviceConfigurationOverride.FontScale(if (large) 2f else 1f)) {
                TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().systemBarsPadding(), color = DarkColors.background) { content() }
                } }
            }
        }
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.getExternalFilesDir(null), name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
    private fun assertUnclippedLabel(name: String) {
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(name, useUnmergedTree = true).assertIsDisplayed()
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals(1, layouts.single().lineCount)
        assertFalse("The compact label must fit", layouts.single().isLineEllipsized(0))
    }
    @Test fun narrowComposerKeepsModelAndSetupReachable() {
        var setup = false
        var current by mutableStateOf(chat)
        compose.setContent { Screen {
            Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.Bottom) {
                ChatComposer(current, "A draft", {}, "Message", false, staged = emptyList(), onPick = {}, onRemove = {},
                    onSend = {}, onStop = {}, onChange = { _, _ -> }, backends = emptyList(), onAgent = {},
                    onSetup = { setup = true }, quota = { ChatQuotaBadge(reading) {} })
            }
        } }
        assertUnclippedLabel("gpt-6.1-sol")
        compose.onNodeWithContentDescription(chatAgentSummary(emptyList(), chat)).assertIsDisplayed()
        compose.onNodeWithContentDescription(L10n.text("android.chatpullssections.chat_setup.9fa79d00")).performClick()
        assertTrue(setup)
        compose.onNodeWithText(L10n.text("android.chatpullssections.plan.fa8ed0bd")).assertDoesNotExist()
        screenshot("composer-small-codex.png")
        compose.runOnIdle { current = JsonObject(chat + ("backend" to JsonPrimitive("claude"))) }
        assertUnclippedLabel("gpt-6.1-sol")
    }
    @Test fun standardPhoneKeepsModelAndActionsOnOneRow() {
        compose.setContent { Screen(width = 360) {
            Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.Bottom) {
                ChatComposer(chat, "", {}, "Message", false, staged = emptyList(), onPick = {}, onRemove = {},
                    onSend = {}, onStop = {}, onChange = { _, _ -> }, backends = emptyList(), onAgent = {},
                    onSetup = {}, quota = { ChatQuotaBadge(reading) {} })
            }
        } }
        assertUnclippedLabel("gpt-6.1-sol")
        val modelBounds = compose.onNodeWithText("gpt-6.1-sol", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val setupBounds = compose.onNodeWithContentDescription(L10n.text("android.chatpullssections.chat_setup.9fa79d00")).getUnclippedBoundsInRoot()
        assertEquals("Normal small phones keep the picker and actions on one row",
            (modelBounds.top.value + modelBounds.bottom.value) / 2f,
            (setupBounds.top.value + setupBounds.bottom.value) / 2f, 1f)
        screenshot("composer-standard-codex.png")
    }
    @Test fun largeTextKeepsTheModelReadable() {
        val claude = JsonObject(chat + ("backend" to JsonPrimitive("claude")))
        compose.setContent { Screen(large = true) {
            Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.Bottom) {
                ChatComposer(claude, "", {}, "Message", false, staged = emptyList(), onPick = {}, onRemove = {}, onSend = {}, onStop = {},
                    onChange = { _, _ -> }, backends = emptyList(), onAgent = {}, quota = { ChatQuotaBadge(reading) {} })
            }
        } }
        assertUnclippedLabel("gpt-6.1-sol")
        screenshot("composer-large-agent.png")
    }
    @Test fun longProviderModelsStayOnOneLineAndOpenThePicker() {
        val longChat = JsonObject(chat + mapOf("backend" to JsonPrimitive("opencode"),
            "model" to JsonPrimitive("provider/some-very-long-model-name"), "effort" to JsonPrimitive("medium")))
        var opened = false
        compose.setContent { Screen {
            Row(Modifier.width(200.dp).padding(8.dp)) {
                ChatComposerAgentField(emptyList(), longChat, { opened = true }, true)
            }
        } }
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText("provider/some-very-long-model-name", useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals(1, layouts.single().lineCount)
        compose.onNodeWithContentDescription(chatAgentSummary(emptyList(), longChat)).performClick()
        assertTrue(opened)
    }
    private fun screenBounds(text: String): Rect {
        fun find(node: AccessibilityNodeInfo?): Rect? {
            if (node == null) return null
            if (node.text?.toString() == text) return Rect().also { node.getBoundsInScreen(it) }
            for (i in 0 until node.childCount) find(node.getChild(i))?.let { return it }
            return null
        }
        return find(InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow)
            ?: error("Missing native accessibility text: $text")
    }
    @Test fun usagePreviewKeepsItsScreenPositionWhileReadingsRefresh() {
        var current by mutableStateOf(reading)
        compose.setContent { Screen {
            Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.Bottom) {
                ChatQuotaBadge(current) {}
            }
        } }
        compose.onNodeWithContentDescription(L10n.text("common.chat.usage.allowance", "Codex", "5-hour", "36")).performClick()
        compose.waitForIdle()
        val initial = screenBounds("Codex")
        for (i in 0..5) {
            compose.runOnIdle { current = JsonObject(reading + ("stale" to JsonPrimitive(i % 2 == 0)) +
                ("observedAtMs" to JsonPrimitive(1793934000000L + i * 1000))) }
            compose.waitForIdle()
            assertEquals("Freshness updates must not move the popup", initial, screenBounds("Codex"))
        }
        screenshot("composer-usage-stable.png")
    }
    @Test fun setupSavesModeAndPermissionsAndKeepsDoneVisible() {
        var current by mutableStateOf(chat)
        val changes = mutableListOf<Pair<String, String>>()
        compose.setContent { Screen {
            ChatSetupSheetFrame({}) {
                ChatSetupBasics(current, emptyList(), current.bol("running"), {}) { field, value ->
                    changes += field to value
                    current = JsonObject(current + (field to JsonPrimitive(value)))
                }
            }
        } }
        compose.onNodeWithText(L10n.text("android.chatpullssections.plan.fa8ed0bd")).performScrollTo().performClick()
        compose.onNodeWithText(L10n.text("android.chatpullssections.ask_first.4a9e8cf3")).performScrollTo().performClick()
        assertEquals(listOf("mode" to "plan", "autonomy" to "standard"), changes)
        compose.onNodeWithText(L10n.text("common.done")).assertIsDisplayed()
        screenshot("chat-setup-organized.png")
        compose.runOnIdle { current = JsonObject(current + ("running" to JsonPrimitive(true))) }
        compose.onNodeWithText(L10n.text("android.chatpullssections.don_t_ask.15dae980")).assertIsNotEnabled()
    }

    @Test fun setupWaitsForAnAgentWithoutClaimingATurnIsRunning() {
        var current by mutableStateOf<JsonObject?>(null)
        var locked by mutableStateOf(true)
        val changes = mutableListOf<Pair<String, String>>()
        compose.setContent { Screen {
            ChatSetupSheetFrame({}) {
                ChatSetupBasics(current, emptyList(), locked, {}) { field, value -> changes += field to value }
            }
        } }
        compose.onNodeWithText(L10n.text("common.chat.setup.busy")).assertDoesNotExist()
        compose.onNodeWithText(L10n.text("common.chat.setup.needs_agent")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("android.chatpullssections.plan.fa8ed0bd")).assertIsNotEnabled()
        compose.runOnIdle { locked = false }
        compose.onNodeWithText(L10n.text("android.chatpullssections.plan.fa8ed0bd")).assertIsNotEnabled()
        compose.runOnIdle { current = chat }
        compose.onNodeWithText(L10n.text("android.chatpullssections.plan.fa8ed0bd")).performScrollTo().performClick()
        assertEquals(listOf("mode" to "plan"), changes)
    }
}
