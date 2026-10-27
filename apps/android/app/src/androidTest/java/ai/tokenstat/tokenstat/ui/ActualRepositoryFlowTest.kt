// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ClientState
import ai.tokenstat.tokenstat.MainActivity
import ai.tokenstat.tokenstat.ui.localization.L10n
import android.Manifest
import android.os.Build
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.TestRule
import org.junit.runners.model.Statement

/** Real activity and navigation, with an isolated in-memory account and connection. */
@RunWith(AndroidJUnit4::class)
class ActualRepositoryFlowTest {
    @get:Rule(order = 0) val notifications = TestRule { base, _ ->
        object : Statement() {
            override fun evaluate() {
                val instrumentation = InstrumentationRegistry.getInstrumentation()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName, Manifest.permission.POST_NOTIFICATIONS)
                }
                base.evaluate()
            }
        }
    }
    @get:Rule(order = 1) val compose = createAndroidComposeRule<MainActivity>()

    private fun seed(model: AppViewModel, machines: List<JsonObject>, thisMachineId: String? = null) {
        val account = buildJsonObject {
            put("signedIn", true); put("canRemote", true); put("tier", "free")
            put("host", "https://fixture.invalid"); put("accountId", "visual-fixture")
            put("handle", "visual-fixture"); put("displayName", "Visual fixture")
            put("machines", JsonArray(machines))
            if (thisMachineId != null) put("thisMachineId", thisMachineId)
        }
        compose.runOnUiThread {
            AppViewModel::class.java.getDeclaredField("refreshJob").apply { isAccessible = true }
                .get(model).let { (it as? Job)?.cancel() }
            @Suppress("UNCHECKED_CAST")
            val state = AppViewModel::class.java.getDeclaredField("mutableState").apply { isAccessible = true }
                .get(model) as MutableStateFlow<ClientState>
            state.value = ClientState(loading = false, account = account, authChecked = true)
        }
    }

    @Test fun actualRepositoriesAndNewChatEmptyStates() {
        val model = ViewModelProvider(compose.activity)[AppViewModel::class.java]
        val olderPhoneRecord = buildJsonObject { put("id", "this-phone"); put("label", "Phone") }
        seed(model, listOf(olderPhoneRecord), thisMachineId = "this-phone")
        val devices = L10n.text("common.devices")
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText(devices) or hasContentDescription(devices)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onAllNodes(hasText(devices) or hasContentDescription(devices)).onFirst().performClick()
        compose.onNodeWithText(L10n.text("android.tokenstatapp.no_computer_connected")).assertIsDisplayed()

        seed(model, emptyList())
        val repositories = L10n.text("common.projects")
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText(repositories) or hasContentDescription(repositories)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onAllNodes(hasText(repositories) or hasContentDescription(repositories)).onFirst().performClick()
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(L10n.text("android.tokenstatapp.no_machine_yet.3ea83dc9")).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(L10n.text("android.tokenstatapp.new_chat.db18382a")).performClick()
        compose.onNodeWithText(L10n.text("android.tokenstatapp.no_computer_connected")).assertIsDisplayed()
        compose.onAllNodes(hasText(repositories) or hasContentDescription(repositories)).assertCountEquals(0)
        compose.onNodeWithContentDescription(L10n.text("common.close")).performClick()
        compose.onAllNodes(hasText(repositories) or hasContentDescription(repositories)).onFirst().assertIsDisplayed()

        val machine = buildJsonObject {
            put("id", "visual-computer"); put("kind", "host"); put("platform", "macos")
            put("label", "Studio"); put("publicIdentity", "a".repeat(64)); put("online", true)
        }
        compose.runOnUiThread {
            model.workspacesConnection.setHost(machine)
            model.workspacesConnection.setConnected("a".repeat(64), true)
            model.workspacesConnection.setLists(JsonArray(emptyList()), JsonArray(emptyList()), JsonArray(emptyList()))
        }
        seed(model, listOf(machine))
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(L10n.text("common.projects.first_title")).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(L10n.text("common.add_project")).assertIsDisplayed()
    }
}
