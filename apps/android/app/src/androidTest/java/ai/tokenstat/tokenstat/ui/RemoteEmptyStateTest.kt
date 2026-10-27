// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.LightColors
import ai.tokenstat.tokenstat.ui.theme.TsColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import ai.tokenstat.tokenstat.ui.workspace.EmptyWorkspacesCard
import ai.tokenstat.tokenstat.ui.workspace.NewChatScreen
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.lifecycle.ViewModelProvider
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RemoteEmptyStateTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun check(colors: TsColors) {
        val opens = AtomicInteger()
        compose.setContent {
            TsTheme(colors) {
                MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                        Column(Modifier.fillMaxWidth().padding(16.dp)) { NoComputerConnected { opens.incrementAndGet() } }
                    }
                }
            }
        }
        compose.onNodeWithText(L10n.text("android.tokenstatapp.no_computer_connected")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("android.tokenstatapp.connect_your_computer")).assertIsDisplayed()
        val action = compose.onNodeWithText(L10n.text("android.tokenstatapp.set_up_a_machine.43e10e13"))
        action.assertIsDisplayed()
        action.performClick()
        assertEquals(1, opens.get())
    }

    @Test fun dark() = check(DarkColors)
    @Test fun light() = check(LightColors)

    private fun checkNoRepositories(colors: TsColors) {
        val adds = AtomicInteger()
        val clones = AtomicInteger()
        compose.setContent {
            TsTheme(colors) {
                MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                        Column(Modifier.fillMaxWidth().padding(16.dp)) {
                            EmptyWorkspacesCard("Studio", { adds.incrementAndGet() }, { clones.incrementAndGet() })
                        }
                    }
                }
            }
        }
        compose.onNodeWithText(L10n.text("common.projects.first_title")).assertIsDisplayed()
        compose.onNodeWithText(L10n.text("common.projects.remote_first_message", "Studio")).assertIsDisplayed()
        val add = compose.onNodeWithText(L10n.text("common.add_project"))
        val clone = compose.onNodeWithText(L10n.text("android.hostworkspaces.clone_a_repository.749e5d4d"))
        add.assertIsDisplayed(); clone.assertIsDisplayed()
        add.performClick(); clone.performClick()
        assertEquals(1, adds.get()); assertEquals(1, clones.get())
    }

    @Test fun noRepositoriesDark() = checkNoRepositories(DarkColors)
    @Test fun noRepositoriesLight() = checkNoRepositories(LightColors)

    private fun checkNewChatWithoutComputer(colors: TsColors) {
        val opens = AtomicInteger()
        val model = ViewModelProvider(compose.activity)[AppViewModel::class.java]
        compose.setContent {
            TsTheme(colors) {
                MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
                    NewChatScreen(
                        model = model, accountOwner = null, accountScope = null, onSetup = {},
                        draft = "", staged = emptyList(), onDraft = {}, hosts = emptyList(),
                        connectedPeer = null, connecting = false, folders = emptyList(),
                        selectedRepository = null, onRepository = {}, onHost = {}, onAdd = {},
                        onSend = {}, onClose = {}, onSetupMachine = { opens.incrementAndGet() },
                    )
                }
            }
        }
        compose.onNodeWithText(L10n.text("android.tokenstatapp.no_computer_connected")).assertIsDisplayed()
        val setup = compose.onNodeWithText(L10n.text("android.tokenstatapp.set_up_a_machine.43e10e13"))
        setup.assertIsDisplayed()
        setup.performClick()
        assertEquals(1, opens.get())
    }

    @Test fun newChatWithoutComputerDark() = checkNewChatWithoutComputer(DarkColors)
    @Test fun newChatWithoutComputerLight() = checkNewChatWithoutComputer(LightColors)
}
