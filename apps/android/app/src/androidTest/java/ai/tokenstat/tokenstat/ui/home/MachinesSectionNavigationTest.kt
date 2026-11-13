// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.home

import ai.tokenstat.tokenstat.ui.localization.L10n
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MachinesSectionNavigationTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun machineRowsOpenTheSelectedDeviceAndHeaderOpensTheList() {
        var openedDevice: String? = null
        var openedList = 0
        compose.setContent {
            MachinesSection(
                machines = listOf(
                    HomeMachine("mac-id", "mac-peer", "MacBook", true),
                    HomeMachine("server-id", "server-peer", "Server", true),
                ),
                onOpenDevice = { openedDevice = it },
                onOpenDevices = { openedList++ },
            )
        }
        compose.onNodeWithText("MacBook").performClick()
        compose.runOnIdle { assertEquals("mac-id", openedDevice) }
        compose.onNodeWithText("Server").performClick()
        compose.runOnIdle { assertEquals("server-id", openedDevice) }
        compose.onNodeWithText(L10n.text("common.devices")).performClick()
        compose.runOnIdle { assertEquals(1, openedList) }
    }
}
