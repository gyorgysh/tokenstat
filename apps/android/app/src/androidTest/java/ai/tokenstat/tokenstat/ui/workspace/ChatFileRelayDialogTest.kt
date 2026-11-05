// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class ChatFileRelayDialogTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Composable private fun ConsentTheme(content: @Composable () -> Unit) {
        TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography, content = content) }
    }
    private fun account(owner: String = "one", used: Long = 4L * 1024 * 1024 * 1024) = buildJsonObject {
        put("host", "https://fixture.invalid"); put("accountId", owner); put("handle", owner); put("accountSession", owner)
        put("relayUsage", buildJsonObject {
            put("policy", "rolling_30_utc_days"); put("windowDays", 30); put("timezone", "UTC")
            put("usedBytes", used); put("limitBytes", 20L * 1024 * 1024 * 1024)
            put("remainingBytes", 16L * 1024 * 1024 * 1024)
        })
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.getExternalFilesDir(null), name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
    @Test fun allowanceAndFileAreVisibleAndContinueApproves() {
        var answer: Boolean? = null
        compose.setContent { ConsentTheme { ChatFileRelayDialog("scene.glb", 24L * 1024 * 1024, 1, account()) { answer = it } } }
        compose.onNodeWithText("4 GiB of 20 GiB used").assertExists()
        compose.onNodeWithText("16 GiB remaining").assertExists()
        compose.onNodeWithText("24 MiB").assertExists()
        compose.onNodeWithContentDescription(L10n.text("common.chat_files_relay_usage_label")).assertExists()
        screenshot("relay-consent.png")
        compose.onNodeWithText(L10n.text("common.continue")).performClick()
        assertEquals(true, answer)
    }
    @Test fun largeTextKeepsBothActionsReachable() {
        var answer: Boolean? = null
        compose.setContent { ConsentTheme {
            DeviceConfigurationOverride(DeviceConfigurationOverride.FontScale(2f)) {
                ChatFileRelayDialog("a long filename for the scene and its textures.glb", 250L * 1024 * 1024, null, account()) { answer = it }
            }
        } }
        compose.onNodeWithText(L10n.text("common.continue")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("common.cancel")).assertIsDisplayed()
        compose.onNodeWithText("16 GiB remaining").performScrollTo().assertIsDisplayed()
        screenshot("relay-consent-large-text.png")
        compose.onNodeWithText(L10n.text("common.cancel")).performClick()
        assertEquals(false, answer)
    }
    @Test fun oldAccountDoesNotInventAQuota() {
        compose.setContent { ConsentTheme { ChatFileRelayDialog("image.png", null, 1024, null) {} } }
        compose.onNodeWithText("1 KiB remaining").assertExists()
        compose.onNodeWithText(L10n.text("common.chat_files_size_unknown")).assertExists()
        compose.onNodeWithText(L10n.text("common.chat_files_relay_usage_unknown")).assertExists()
        compose.onNodeWithContentDescription(L10n.text("common.chat_files_relay_usage_label")).assertDoesNotExist()
    }
    @Test fun refreshUsesOnlyTheCurrentAccountsCounters() {
        val current = mutableStateOf(account())
        val first = CompletableDeferred<JsonObject?>(); val second = CompletableDeferred<JsonObject?>()
        val calls = AtomicInteger()
        compose.setContent { ConsentTheme {
            ChatFileRelayDialog("scene.glb", 1024, null, current.value,
                loadAllowance = { if (calls.getAndIncrement() == 0) first.await() else second.await() }) {}
        } }
        compose.waitUntil(5_000) { calls.get() == 1 }
        compose.onNodeWithText(L10n.text("common.continue")).assertIsEnabled()
        first.complete(account("foreign", 9L * 1024 * 1024 * 1024))
        compose.waitForIdle()
        compose.onNodeWithText("4 GiB of 20 GiB used").assertExists()
        compose.onNodeWithText("9 GiB of 20 GiB used").assertDoesNotExist()
        compose.runOnIdle { current.value = account("two") }
        compose.waitUntil(5_000) { calls.get() == 2 }
        second.complete(account("two", 5L * 1024 * 1024 * 1024))
        compose.waitUntil(5_000) { compose.onAllNodesWithText("5 GiB of 20 GiB used").fetchSemanticsNodes().size == 1 }
    }
}
