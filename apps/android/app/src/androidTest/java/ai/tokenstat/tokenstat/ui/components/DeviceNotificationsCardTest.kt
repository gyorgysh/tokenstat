// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import org.junit.Assert.*
import org.junit.Assume.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceNotificationsCardTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val label = L10n.text("android.tokenstatapp.notify_this_device.961006a8")
    private val blocked = L10n.text("android.notifications.permission_blocked")
    private fun show(initial: Boolean = false, access: (Context) -> Boolean = { true },
        update: suspend (Boolean) -> Unit = {}, test: suspend () -> String? = { null }) {
        var stored = initial
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize()) {
                        Column { DeviceNotificationsCard({ stored }, { update(it); stored = it }, test, access) }
                    }
                }
            }
        }
    }
    @Test fun permissionDoesNotEnableDeliveryUntilTheSwitchIsUsed() {
        val changes = mutableListOf<Boolean>()
        show(update = { changes += it })
        compose.onNodeWithContentDescription(label).assertIsOff().performClick()
        compose.onNodeWithContentDescription(label).assertIsOn().performClick()
        compose.onNodeWithContentDescription(label).assertIsOff()
        assertEquals(listOf(true, false), changes)
    }
    @Test fun blockedSystemNotificationsExplainRecoveryAndCanStillBeTurnedOff() {
        val changes = mutableListOf<Boolean>()
        show(initial = true, access = { false }, update = { changes += it })
        compose.onNodeWithText(blocked).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("android.notifications.open_settings")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("android.tokenstatapp.send_a_test.edc01436")).assertDoesNotExist()
        compose.onNodeWithContentDescription(label).performClick().assertIsOff()
        compose.onNodeWithText(blocked).assertDoesNotExist()
        assertEquals(listOf(false), changes)
    }
    @Test fun failedPreferenceChangeShowsTheErrorAndAllowsRetry() {
        show(update = { throw IllegalStateException("fixture registration failed") })
        compose.onNodeWithContentDescription(label).performClick().assertIsOff().assertIsEnabled()
        compose.onNodeWithText("fixture registration failed").assertIsDisplayed()
    }
    @Test fun testDeliveryReportsItsResult() {
        show(initial = true, test = { "fixture test result" })
        compose.onNodeWithText(L10n.text("android.tokenstatapp.send_a_test.edc01436")).performClick()
        compose.onNodeWithText("fixture test result").assertIsDisplayed()
    }
    @Test fun denyingTheRealSystemPromptDoesNotEnableDelivery() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val instrument = InstrumentationRegistry.getInstrumentation()
        assumeFalse(ContextCompat.checkSelfPermission(instrument.targetContext, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
        var changes = 0
        show(access = { NotificationManagerCompat.from(it).areNotificationsEnabled() }, update = { changes++ })
        compose.onNodeWithText(blocked).assertDoesNotExist()
        compose.onNodeWithContentDescription(label).performClick()
        var deny: AccessibilityNodeInfo? = null
        compose.waitUntil(5_000) {
            deny = instrument.uiAutomation.rootInActiveWindow
                ?.findAccessibilityNodeInfosByViewId("com.android.permissioncontroller:id/permission_deny_button")?.firstOrNull()
            deny != null
        }
        assertTrue(deny!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        compose.onNodeWithContentDescription(label).assertIsOff().assertIsEnabled()
        compose.onNodeWithText(blocked).assertIsDisplayed()
        assertEquals(0, changes)
    }
}
