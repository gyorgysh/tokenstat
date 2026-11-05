// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.DpSize
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ChatUsagePanelTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun json(value: String) = Json.parseToJsonElement(value).jsonObject
    private val reading = json("""{"source":"claude_code","plan":"Max","observedAtMs":1793860000000,"windows":[{"label":"5-hour","percent":36,"severity":"normal"},{"label":"weekly","percent":86,"severity":"warning","resetsAtMs":1794460000000}]}""")
    private val data = json("""{"contextUsed":152432,"contextWindow":200000,"windowSource":"catalog","usage":{"input":194,"output":3800,"cacheRead":13800000,"cacheWrite":200900,"cost":5.75}}""")
    private val chat = json("""{"id":"usage-fixture","backend":"claude","model":"opus","mode":"execute","autonomy":"bypass","running":true}""")
    private val ring = L10n.text("common.chat.usage.allowance", "Claude Code", "5-hour", "36")

    @Composable private fun Theme(content: @Composable () -> Unit) {
        TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) { Surface(color = DarkColors.background, modifier = Modifier.fillMaxSize().systemBarsPadding(), content = content) } }
    }
    @Composable private fun Fixture(large: Boolean = false, onOpen: () -> Unit = {}) {
        DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(DpSize(360.dp, 740.dp))) {
        DeviceConfigurationOverride(DeviceConfigurationOverride.FontScale(if (large) 2f else 1f)) {
            Column(Modifier.fillMaxSize().padding(12.dp)) {
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(L10n.text("common.chat.usage.title"), style = MaterialTheme.typography.titleLarge)
                    ChatUsagePanel(reading, ChatInspectionSnapshot(data, true), null)
                }
                ChatComposer(chat, "", {}, "Message", false, staged = emptyList(), onPick = {}, onRemove = {}, onSend = {}, onStop = {},
                    onChange = { _, _ -> }, backends = emptyList(), onAgent = {}, launchMode = "execute",
                    quota = { ChatQuotaBadge(reading, onOpen) },
                    routing = { ChatRoutingControls(chat, emptyList(), { _, _ -> JsonNull }, {}, showNotice = false, showSection = false, showShortcut = true) })
            }
        }
        }
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrument = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrument.uiAutomation.takeScreenshot()
        File(instrument.targetContext.getExternalFilesDir(null), name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
    @Test fun usageRingOpensAndSetupControlsRemainReachable() {
        var opened = false
        compose.setContent { Theme { Fixture(onOpen = { opened = true }) } }
        compose.onNodeWithContentDescription(ring).assertIsDisplayed().performClick()
        assertTrue(opened)
        compose.onNodeWithText(L10n.text("android.chatpullssections.ask_first.4a9e8cf3")).assertDoesNotExist()
        screenshot("usage-android.png")
        compose.onNodeWithContentDescription(L10n.text("common.settings")).performClick()
        compose.onNodeWithText(L10n.text("android.chatpullssections.plan.fa8ed0bd")).assertExists()
        compose.onNodeWithText(L10n.text("common.chat.stats.cost")).performScrollTo().assertIsDisplayed()
    }
    @Test fun largeTextStillShowsCostAndTheQuotaControl() {
        compose.setContent { Theme { Fixture(large = true) } }
        compose.onNodeWithContentDescription(ring).assertIsDisplayed()
        screenshot("usage-android-large.png")
        compose.onNodeWithText(L10n.text("common.chat.stats.cost")).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("$5.75").performScrollTo().assertIsDisplayed()
        screenshot("usage-android-large-cost.png")
    }
    @Test fun oldHostTotalsDoNotRequireContextAndUnknownDataDoesNotShowAQuota() {
        compose.setContent { Theme {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                ChatUsagePanel(null, ChatInspectionSnapshot(null, true), ChatUsageTotals.decode(data["usage"] as? JsonObject))
                ChatQuotaBadge(null) { fail("No quota should be tappable") }
            }
        } }
        compose.onNodeWithText(L10n.text("common.chat.usage.no_limits")).assertExists()
        compose.onNodeWithText(L10n.text("common.chat.stats.cost")).assertExists()
        compose.onNodeWithContentDescription(ring).assertDoesNotExist()
    }
    @Test fun zeroWeeklyAndStaleIndicatorsKeepTheirMeaning() {
        val current = mutableStateOf(chatQuotaReading(JsonArray(listOf(reading)), "claude"))
        compose.setContent { Theme {
            Column { ChatQuotaBadge(current.value) {} }
        } }
        val zero = JsonObject(reading + ("windows" to JsonArray(listOf(json("""{"label":"5-hour","percent":0}""")))))
        compose.runOnIdle { current.value = zero }
        compose.onNodeWithContentDescription(L10n.text("common.chat.usage.allowance", "Claude Code", "5-hour", "0")).assertExists()
        screenshot("usage-android-zero.png")
        val weekly = JsonObject(reading + ("windows" to JsonArray(listOf(json("""{"label":"weekly","percent":86,"severity":"warning"}""")))) + ("stale" to JsonPrimitive(true)))
        compose.runOnIdle { current.value = weekly }
        compose.onNodeWithContentDescription(L10n.text("common.chat.usage.allowance", "Claude Code", "weekly", "86"))
            .assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription, L10n.text("common.chat.usage.stale")))
        compose.runOnIdle { current.value = null }
        compose.onNodeWithContentDescription(L10n.text("common.chat.usage.allowance", "Claude Code", "weekly", "86")).assertDoesNotExist()
    }

    @Test fun missingTelemetryDoesNotBecomeZeroTokenAndCostRows() {
        val empty = json("""{"usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"cost":0}}""")
        compose.setContent { Theme {
            Column { ChatUsagePanel(null, ChatInspectionSnapshot(empty, true), null) }
        } }
        compose.onNodeWithText(L10n.text("common.chat.usage.no_totals")).assertExists()
        compose.onNodeWithText(L10n.text("common.chat.stats.input")).assertDoesNotExist()
        compose.onNodeWithText(L10n.text("common.chat.stats.cost")).assertDoesNotExist()
    }

}
