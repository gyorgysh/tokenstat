// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.ssh.SshLibraryEmptyState
import ai.tokenstat.tokenstat.ui.ssh.VaultManagementSheet
import ai.tokenstat.tokenstat.ui.ssh.VaultPasswordDialog
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.LightColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import ai.tokenstat.tokenstat.ui.workspace.GitTransferActions
import ai.tokenstat.tokenstat.ui.workspace.PullAction
import ai.tokenstat.tokenstat.ui.workspace.PullSheet
import ai.tokenstat.tokenstat.ui.workspace.PushAction
import ai.tokenstat.tokenstat.ui.workspace.PushSheet
import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import android.text.InputType
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.content.ContentValues
import android.provider.MediaStore
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Drives the production forms with controlled host replies; no repository is mutated. */
@RunWith(AndroidJUnit4::class)
class MobileFormsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val calls = CopyOnWriteArrayList<Pair<String, JsonObject>>()
    private val pullReview = obj("""{"state":"fastForward","incoming":2,"outgoing":0,"branch":"refs/heads/main","remote":"origin","remoteRef":"refs/heads/main","head":"abc","upstreamHead":"def"}""")
    private val pushReview = obj("""{"branch":"refs/heads/main","remote":"origin","remoteRef":"refs/heads/main","head":"abc","endpointDigest":"opaque-destination-digest","remoteHead":"def","outgoing":2,"setUpstream":false}""")
    private fun obj(json: String) = Json.parseToJsonElement(json).jsonObject
    private fun text(key: String, vararg args: Any) = L10n.text(key, *args)
    private fun setContent(colors: TsColors = DarkColors, content: @Composable () -> Unit) {
        compose.setContent {
            TsTheme(colors) {
                MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
                    Surface(Modifier.fillMaxSize(), color = colors.danger) { content() }
                }
            }
        }
    }
    private fun screenshot(name: String): Bitmap {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: error("No phone screenshot")
        val resolver = instrumentation.targetContext.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-ui-qa/${InstrumentationRegistry.getArguments().getString("qaVariant", "portrait")}")
        }) ?: error("Cannot save phone screenshot")
        resolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return bitmap
    }
    private fun assertFullScreen(name: String, colors: TsColors = DarkColors) {
        val bitmap = screenshot(name)
        val bounds = compose.onNodeWithTag("modal-screen").fetchSemanticsNode().boundsInRoot
        assertEquals(bitmap.width.toFloat(), bounds.width, 1f)
        assertTrue("Modal should fill the phone, ${bounds.height}/${bitmap.height}", bounds.height >= bitmap.height * 0.98f)
        // The lower body must cover the underlying danger-colored page with an opaque surface.
        assertEquals(colors.background.toArgb(), bitmap.getPixel(bitmap.width - 2, bitmap.height * 3 / 4))
        compose.onNodeWithContentDescription(text("common.close")).assertIsDisplayed()
    }
    private fun imeHeight(): Int = android.view.inspector.WindowInspector.getGlobalWindowViews()
        .mapNotNull { it.rootWindowInsets?.getInsets(android.view.WindowInsets.Type.ime())?.bottom }.maxOrNull() ?: 0
    private fun awaitKeyboardActions() {
        val height = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()!!.height
        compose.waitUntil(5_000) {
            val keyboard = imeHeight()
            val footer = compose.onNodeWithTag("modal-actions").fetchSemanticsNode().boundsInWindow
            keyboard > 0 && footer.height > 0 && footer.bottom <= height - keyboard + 1
        }
        compose.waitForIdle()
    }
    private suspend fun host(method: String, params: JsonObject): JsonElement {
        calls += method to params
        return when (method) {
            "workspace.pullReview" -> pullReview
            "workspace.pullReviewed" -> obj("""{"ok":true,"message":"Pulled 2 commits."}""")
            "workspace.pushReview" -> pushReview
            "workspace.pushReviewed" -> buildJsonObject {
                put("operationId", params.getValue("operationId"))
                put("review", params.getValue("review"))
                put("state", "succeeded")
                put("message", "Pushed 2 commits.")
            }
            else -> error("Unexpected request $method")
        }
    }

    @Test fun transferButtonsMatchAndPullReviewsBeforeSending() {
        setContent {
            Surface(Modifier.fillMaxSize(), color = DarkColors.background) {
                Column(Modifier.safeDrawingPadding().padding(Space.l)) {
                    Text("Changes", style = TsType.title3)
                    GitTransferActions(
                        pull = { PullAction(::host, "qa-peer", "qa-folder", "Project", "Computer", 0, 30, it) {} },
                        push = { PushAction(::host, "qa-peer", "qa-folder", "Project", "Computer", 0, 30, it) {} },
                    )
                }
            }
        }
        val pull = compose.onNodeWithText(text("android.gitpull.pull"))
        val push = compose.onNodeWithText(ai.tokenstat.tokenstat.ui.logic.PushLabel.label(false, 0))
        val left = pull.fetchSemanticsNode().boundsInRoot
        val right = push.fetchSemanticsNode().boundsInRoot
        assertEquals(left.width, right.width, 1f)
        assertEquals(left.height, right.height, 1f)
        assertTrue(left.height >= 48 * compose.activity.resources.displayMetrics.density)
        screenshot("changes-actions-dark")
        pull.performClick()
        compose.onNodeWithText(text("android.gitpull.pull_commits.other", "2")).assertIsDisplayed()
        assertEquals(listOf("workspace.pullReview"), calls.map { it.first })
        assertFullScreen("pull-review-dark")
        compose.onNodeWithText(text("android.gitpull.pull_commits.other", "2")).performClick()
        compose.onNodeWithText("Pulled 2 commits.").assertIsDisplayed()
        assertEquals(pullReview, calls.last().second["review"])
        compose.onNodeWithText(text("common.done")).assertIsDisplayed()
    }

    @Test fun pushOnlySendsTheExplicitlyReviewedBranch() {
        var cleared = false
        var pushed = 0
        setContent {
            PushSheet(::host, "qa-folder", "Project", "Computer", true, null,
                onOperationId = { if (it == null) cleared = true }, onDismiss = {}, onPushed = { pushed++ })
        }
        val button = compose.onAllNodesWithText(text("android.workspacecommit.push_branch.97deb7c0")).filter(hasClickAction()).onFirst()
        button.assertIsDisplayed()
        assertEquals(listOf("workspace.pushReview"), calls.map { it.first })
        assertFullScreen("push-review-dark")
        button.performClick()
        compose.onNodeWithText("Pushed 2 commits.").assertIsDisplayed()
        assertEquals(pushReview, calls.last().second["review"])
        assertEquals(false, calls.last().second["retry"]?.jsonPrimitive?.boolean)
        assertTrue(cleared)
        assertEquals(1, pushed)
    }

    @Test fun pullFailureOffersAVisibleRetryAndNeverPullsAutomatically() {
        var fail = true
        setContent {
            PullSheet(request = { method, params ->
                if (fail) { fail = false; throw IllegalStateException("Connection interrupted") }
                host(method, params)
            }, "qa-folder", "Project", "Computer", {}, {})
        }
        compose.onNodeWithText("Connection interrupted").assertIsDisplayed()
        assertFullScreen("pull-error-dark")
        compose.onNodeWithText(text("android.gitpull.check_again")).performClick()
        compose.onNodeWithText(text("android.gitpull.pull_commits.other", "2")).assertIsDisplayed()
        assertEquals(listOf("workspace.pullReview"), calls.map { it.first })
    }

    @Test fun closingPullDiscardsALateReadResponse() {
        val reply = CompletableDeferred<JsonElement>()
        var refreshed = 0
        setContent {
            var open by remember { mutableStateOf(true) }
            if (open) PullSheet(request = { _, _ -> withContext(NonCancellable) { reply.await() } },
                "qa-folder", "Project", "Computer", onDismiss = { open = false }, onPulled = { refreshed++ })
        }
        compose.onNodeWithContentDescription(text("common.close")).performClick()
        compose.runOnIdle { reply.complete(pullReview) }
        compose.waitForIdle()
        compose.onNodeWithTag("modal-screen").assertDoesNotExist()
        assertEquals(0, refreshed)
    }

    @Test fun failedReceiptReadNeverEnablesRetryAndConfirmedAbsenceRetriesTheSamePush() {
        var receiptUnavailable = true
        var operation: String? = null
        setContent {
            PushSheet(request = { method, params ->
                when (method) {
                    "workspace.pushReviewed" -> { calls += method to params; throw IllegalStateException("Response lost") }
                    "workspace.pushReceipt" -> {
                        calls += method to params
                        if (receiptUnavailable) throw IllegalStateException("Computer unreachable") else JsonNull
                    }
                    else -> host(method, params)
                }
            }, "qa-folder", "Project", "Computer", true, null, { operation = it }, {}, {})
        }
        compose.onAllNodesWithText(text("android.workspacecommit.push_branch.97deb7c0")).filter(hasClickAction()).onFirst().performClick()
        compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd")).performClick()
        compose.onNodeWithText(text("android.workspacecommit.retry_same_push.d4ab8f02")).assertDoesNotExist()
        compose.runOnIdle { receiptUnavailable = false }
        compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd")).performClick()
        val retry = compose.onNodeWithText(text("android.workspacecommit.retry_same_push.d4ab8f02"))
        retry.assertIsDisplayed().assertIsEnabled()
        assertFullScreen("push-retry-dark")
        val originalOperation = operation
        retry.performClick()
        assertEquals(originalOperation, operation)
        assertEquals(pushReview, calls.last().second["review"])
        assertEquals(true, calls.last().second["retry"]?.jsonPrimitive?.boolean)
    }

    @Test fun reopenedPushWithNoReceiptRequiresAFreshExplicitReview() {
        var cleared = false
        setContent {
            PushSheet(request = { method, params ->
                if (method == "workspace.pushReceipt") { calls += method to params; JsonNull }
                else host(method, params)
            }, "qa-folder", "Project", "Computer", true, "saved-operation", { cleared = it == null }, {}, {})
        }
        assertTrue(calls.isEmpty())
        compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd")).performClick()
        compose.onNodeWithText(text("android.workspacecommit.missing_receipt_review_again")).assertIsDisplayed()
        compose.onNodeWithText(text("android.workspacecommit.retry_same_push.d4ab8f02")).assertDoesNotExist()
        assertTrue(cleared)
        compose.onNodeWithText(text("android.workspacecommit.check_branch.8128e71f")).performClick()
        compose.onAllNodesWithText(text("android.workspacecommit.push_branch.97deb7c0")).filter(hasClickAction()).onFirst().assertIsDisplayed()
        assertEquals(listOf("workspace.pushReceipt", "workspace.pushReview"), calls.map { it.first })
    }

    @Test fun recoveredPushRetriesOnlyTheSavedOperationAndReview() {
        setContent {
            PushSheet(request = { method, params ->
                calls += method to params
                when (method) {
                    "workspace.pushReceipt", "workspace.pushRecover" -> buildJsonObject {
                        put("operationId", "saved-operation")
                        put("review", pushReview)
                        put("state", if (method == "workspace.pushReceipt") "started" else "unknown")
                        put("retryAllowed", method == "workspace.pushRecover")
                    }
                    "workspace.pushReviewed" -> buildJsonObject {
                        put("operationId", params.getValue("operationId"))
                        put("review", params.getValue("review"))
                        put("state", "succeeded")
                    }
                    else -> error("Recovery must not prepare a different push")
                }
            }, "qa-folder", "Project", "Computer", true, "saved-operation", {}, {}, {})
        }
        assertTrue(calls.isEmpty())
        compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd")).performClick()
        assertEquals(listOf("workspace.pushReceipt", "workspace.pushRecover"), calls.map { it.first })
        compose.onNodeWithText(text("android.workspacecommit.retry_same_push.d4ab8f02")).performClick()
        assertEquals("workspace.pushReviewed", calls.last().first)
        assertEquals("saved-operation", calls.last().second["operationId"]?.jsonPrimitive?.content)
        assertEquals(pushReview, calls.last().second["review"])
        assertEquals(true, calls.last().second["retry"]?.jsonPrimitive?.boolean)
    }

    @Test fun recoveryRejectsReceiptsForAnotherOperationOrReview() {
        var stage = 0
        var cleared = false
        setContent {
            PushSheet(request = { method, params ->
                calls += method to params
                buildJsonObject {
                    put("operationId", if (stage == 0) "another-operation" else "saved-operation")
                    put("review", if (stage == 1 && method == "workspace.pushRecover")
                        JsonObject(pushReview + ("head" to JsonPrimitive("another-head"))) else pushReview)
                    put("state", if (method == "workspace.pushReceipt") "started" else "succeeded")
                }
            }, "qa-folder", "Project", "Computer", true, "saved-operation", { cleared = it == null }, {}, {})
        }
        val check = compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd"))
        check.performClick()
        assertEquals(listOf("workspace.pushReceipt"), calls.map { it.first })
        assertFalse(cleared)
        compose.onNodeWithText(text("android.workspacecommit.retry_same_push.d4ab8f02")).assertDoesNotExist()
        compose.runOnIdle { stage = 1 }
        check.performClick()
        assertFalse(cleared)
        compose.onNodeWithText(text("android.workspacecommit.retry_same_push.d4ab8f02")).assertDoesNotExist()
        compose.runOnIdle { stage = 2 }
        check.performClick()
        assertTrue(cleared)
        assertTrue(calls.none { it.first == "workspace.pushReviewed" })
    }

    @Test fun vaultManagementCoversTheAppAndOpensTheFullScreenUnlockForm() {
        setContent {
            var unlock by remember { mutableStateOf(false) }
            if (unlock) VaultPasswordDialog(true, false, null, {}, {}, {}, { _, _ -> }, {})
            else VaultManagementSheet(obj("""{"created":true,"locked":true,"enrolled":true}"""), true,
                false, false, false, null, null, {}, { unlock = true }, {}, {}, null, {}, {}, {})
        }
        assertFullScreen("vault-management-dark")
        compose.onNodeWithText(text("android.tokenstatapp.unlock.4ac709aa")).performClick()
        compose.onNodeWithTag("vault-password").assertIsDisplayed()
        assertFullScreen("vault-unlock-dark")
    }

    @Test fun unlockKeepsItsActionAboveTheKeyboardAndLocksControlsWhileWorking() {
        var password: String? = null
        val busy = mutableStateOf(false)
        setContent {
            VaultPasswordDialog(true, busy.value, null, {}, {}, { password = it; busy.value = true }, { _, _ -> }, {})
        }
        val unlock = compose.onNodeWithText(text("android.tokenstatapp.unlock.4ac709aa"))
        unlock.assertIsNotEnabled()
        compose.onNodeWithTag("vault-password").performClick().performTextInput("correct horse")
        // A real IME, rather than simulated insets, verifies the footer on this phone.
        awaitKeyboardActions()
        screenshot("vault-unlock-keyboard-dark")
        unlock.assertIsDisplayed().assertIsEnabled()
        val footer = compose.onNodeWithTag("modal-actions").fetchSemanticsNode().boundsInWindow
        val keyboard = imeHeight()
        val bitmap = screenshot("vault-unlock-keyboard-dark")
        assertTrue("Footer overlaps keyboard", footer.bottom <= bitmap.height - keyboard + 1)
        unlock.performClick()
        assertEquals("correct horse", password)
        compose.onNodeWithTag("vault-password").assertIsNotEnabled()
        compose.onNodeWithContentDescription(text("common.close")).assertIsNotEnabled()
        compose.onNodeWithText(text("android.tokenstatapp.i_forgot_the_password.c3aabb38")).assertIsNotEnabled()
        unlock.assertIsNotEnabled()
    }

    @Test fun recoveryValidatesTheNewPasswordAndConfirmation() {
        var reset: Pair<String, String>? = null
        setContent { VaultPasswordDialog(true, false, null, {}, {}, {}, { code, pass -> reset = code to pass }, {}) }
        compose.onNodeWithText(text("android.tokenstatapp.i_forgot_the_password.c3aabb38")).performClick()
        val submit = compose.onNodeWithText(text("android.tokenstatapp.reset_password.e0edfeb3"))
        submit.assertIsNotEnabled()
        compose.onNodeWithTag("vault-recovery").performTextInput("example recovery words")
        compose.onNodeWithTag("vault-password").performTextInput("A-strong-password-123!")
        submit.assertIsNotEnabled()
        compose.onNodeWithTag("vault-confirm").performScrollTo().performTextInput("A-strong-password-123!")
        submit.assertIsEnabled().assertIsDisplayed()
        screenshot("vault-recovery-keyboard-dark")
        submit.performClick()
        assertEquals("example recovery words" to "A-strong-password-123!", reset)
    }

    @Test fun recoveryKeyboardDoesNotAutocorrectTheSecret() {
        setContent { VaultPasswordDialog(true, false, null, {}, {}, {}, { _, _ -> }, {}) }
        compose.onNodeWithText(text("android.tokenstatapp.i_forgot_the_password.c3aabb38")).performClick()
        compose.onNodeWithTag("vault-recovery").performClick().performTextInput("example recovery words")
        awaitKeyboardActions()
        val dump = ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("dumpsys input_method")
        ).bufferedReader().use { it.readText() }
        val inputType = Regex("inputType=0x([0-9a-fA-F]+)").find(dump)?.groupValues?.get(1)?.toInt(16)
            ?: error("The keyboard has no active input type")
        assertEquals(InputType.TYPE_TEXT_VARIATION_PASSWORD, inputType and InputType.TYPE_MASK_VARIATION)
        assertEquals(0, inputType and InputType.TYPE_TEXT_FLAG_AUTO_CORRECT)
    }

    @Test fun vaultCreateWorksInLightTheme() {
        var created: String? = null
        setContent(LightColors) { VaultPasswordDialog(false, false, null, {}, { created = it }, {}, { _, _ -> }, {}) }
        InstrumentationRegistry.getArguments().getString("expectedFontScale")?.toFloat()?.let {
            assertEquals(it, compose.activity.resources.configuration.fontScale, 0.01f)
        }
        assertFullScreen("vault-create-light", LightColors)
        compose.runOnIdle {
            val view = android.view.inspector.WindowInspector.getGlobalWindowViews().last { it.isShown }
            assertTrue("Light form needs dark status icons", view.windowInsetsController!!.systemBarsAppearance and
                android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS != 0)
        }
        val submit = compose.onNodeWithText(text("android.tokenstatapp.create_vault.c8c44253"))
        submit.assertIsNotEnabled()
        compose.onNodeWithTag("vault-password").performTextInput("A-strong-password-123!")
        compose.onNodeWithTag("vault-confirm").performScrollTo().performTextInput("mismatch")
        submit.assertIsNotEnabled()
        compose.onNodeWithTag("vault-confirm").performTextReplacement("A-strong-password-123!")
        awaitKeyboardActions()
        submit.assertIsEnabled().assertIsDisplayed()
        screenshot("vault-create-keyboard-light")
        submit.performClick()
        assertEquals("A-strong-password-123!", created)
    }

    @Test fun olderHostsShowUpgradeGuidanceWithoutCallingNewMethods() {
        setContent {
            PullAction(::host, "qa-peer", "qa-folder", "Project", "Computer", 0, 29) {}
            PushSheet(::host, "qa-folder", "Project", "Computer", false, null, {}, {}, {})
        }
        compose.onNodeWithText(text("android.gitpull.pull")).assertDoesNotExist()
        compose.onNodeWithText(text("android.workspacecommit.update_this_computer_s_tokenstat_to_review.8147f2b4")).assertIsDisplayed()
        assertTrue(calls.isEmpty())
        assertFullScreen("push-upgrade-dark")
    }

    @Test fun savedPushWaitsForHostUpgradeWithoutLosingItsIdentity() {
        val supported = mutableStateOf(false)
        var cleared = false
        setContent {
            PushSheet(request = { method, params ->
                calls += method to params
                buildJsonObject {
                    put("operationId", params.getValue("operationId"))
                    put("review", pushReview)
                    put("state", "succeeded")
                    put("message", "The saved push succeeded.")
                }
            }, "qa-folder", "Project", "Computer", supported.value, "saved-operation", { cleared = it == null }, {}, {})
        }
        compose.onNodeWithText(text("android.workspacecommit.update_this_computer_s_tokenstat_to_review.8147f2b4")).assertIsDisplayed()
        compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd")).assertDoesNotExist()
        assertTrue(calls.isEmpty())
        assertFalse(cleared)
        compose.runOnIdle { supported.value = true }
        compose.onNodeWithText(text("android.workspacecommit.update_this_computer_s_tokenstat_to_review.8147f2b4")).assertDoesNotExist()
        assertTrue(calls.isEmpty())
        compose.onNodeWithText(text("android.workspacecommit.check_outcome.9200a2fd")).performClick()
        assertEquals(listOf("workspace.pushReceipt"), calls.map { it.first })
        assertEquals("saved-operation", calls.single().second["operationId"]?.jsonPrimitive?.content)
        compose.onNodeWithText("The saved push succeeded.").assertIsDisplayed()
        assertTrue(cleared)
    }

    @Test fun unmatchedSshSearchOffersClearInsteadOfAnEmptyLibrary() {
        var added = false
        setContent {
            var query by remember { mutableStateOf("missing") }
            if (query.isNotBlank()) SshLibraryEmptyState(0, "Hosts", { added = true }, query = query, onClearSearch = { query = "" })
            else Text("Saved host")
        }
        compose.onNodeWithText(text("android.sshlibrary.no_matches")).assertIsDisplayed()
        compose.onNodeWithText(text("android.tokenstatapp.no_0_yet.91be7356", "hosts")).assertDoesNotExist()
        compose.onNodeWithText(text("android.tokenstatapp.add_0.882c2180", "host")).assertDoesNotExist()
        compose.onNodeWithText(text("android.sshlibrary.clear_search")).performClick()
        compose.onNodeWithText("Saved host").assertIsDisplayed()
        assertFalse(added)
    }

    @Test fun emptySshLibraryStaysDirectlyBelowItsControls() {
        var added = false
        setContent {
            Surface(Modifier.fillMaxSize(), color = DarkColors.background) {
                Column(Modifier.safeDrawingPadding()) {
                    Text("SSH", style = TsType.title3, modifier = Modifier.padding(Space.l))
                    ai.tokenstat.tokenstat.ui.ssh.VaultLockRow("qa-owner", obj("""{"created":true,"locked":true,"enrolled":true}"""), true, false, {}, Modifier.padding(horizontal = Space.l))
                    Spacer(Modifier.height(Space.s))
                    ai.tokenstat.tokenstat.ui.components.SegmentedCapsulePicker(
                        options = listOf(Triple(0, "Hosts", null), Triple(1, "Keys", null), Triple(2, "Snippets", null)),
                        selection = 0, onSelect = {}, modifier = Modifier.fillMaxWidth().padding(horizontal = Space.l))
                    Spacer(Modifier.height(Space.s))
                    ai.tokenstat.tokenstat.ui.components.TsSearchField("Search hosts", "", {}, Modifier.fillMaxWidth().padding(horizontal = Space.l))
                    Spacer(Modifier.height(Space.s))
                    SshLibraryEmptyState(0, "Hosts", { added = true }, Modifier.weight(1f))
                }
            }
        }
        val search = compose.onNodeWithText("Search hosts").fetchSemanticsNode().boundsInRoot
        val empty = compose.onNodeWithText(text("android.tokenstatapp.no_0_yet.91be7356", "hosts")).fetchSemanticsNode().boundsInRoot
        assertTrue("Empty state drifted away from controls", empty.top - search.bottom < 100 * compose.activity.resources.displayMetrics.density)
        screenshot("ssh-empty-dark")
        compose.onNodeWithText(text("android.tokenstatapp.add_0.882c2180", "host")).assertIsDisplayed().performClick()
        assertTrue(added)
    }
}
