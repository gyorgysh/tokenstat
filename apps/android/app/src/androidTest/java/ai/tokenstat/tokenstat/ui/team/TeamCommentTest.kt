// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Production storage and composer, with fictional account and lost replies. */
@RunWith(AndroidJUnit4::class)
class TeamCommentTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val target = TeamCommentTarget("https://fixture.invalid", "person-fixture", "org-fixture", "repo-fixture", "checkout-fixture", "share-fixture", "host-fixture")
    @Test fun uncertainCommentSurvivesStorageRestartAndKeepsExplicitRecoveryActions() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.noBackupFilesDir, "team-comment-test-" + UUID.randomUUID())
        val storage = TeamCommentDraftStore(directory)
        val requests = CopyOnWriteArrayList<JsonObject>()
        val model = TeamCommentModel(storage, target, "Fictional shared chat") { _, body -> requests += body; throw java.io.IOException("fictional lost reply") }
        try {
            compose.setContent {
                TsTheme(DarkColors) {
                    MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                        Surface(Modifier.fillMaxSize()) {
                            Column(Modifier.safeDrawingPadding().padding(16.dp)) { TeamCommentComposer(model) {} }
                        }
                    }
                }
            }
            compose.waitUntil(5_000) { model.loaded }
            compose.onNodeWithText(L10n.text("common.teams.comment_placeholder")).performTextInput("Keep these literal words 🙂")
            compose.onNodeWithText(L10n.text("common.teams.post_comment")).performClick()
            compose.waitUntil(5_000) { model.pending && !model.busy }
            compose.onNodeWithText(L10n.text("common.teams.send_same_comment")).assertIsDisplayed()
            compose.onNodeWithText(L10n.text("common.teams.check_delivery")).assertIsDisplayed()
            compose.onNodeWithText(L10n.text("common.teams.send_same_comment")).performClick()
            compose.waitUntil(5_000) { requests.size == 2 && !model.busy }
            assertEquals(requests[0]["input"], requests[1]["input"])
            val restarted = TeamCommentDraftStore(directory)
            assertEquals(model.draft, restarted.load(target))
            assertEquals("Keep these literal words 🙂", restarted.load(target)?.text)
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val screenshot = instrumentation.uiAutomation.takeScreenshot() ?: error("no screenshot")
            val resolver = context.contentResolver
            val image = resolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "teams-comment-uncertain.png")
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-teams-qa")
            }) ?: error("cannot save fictional screenshot")
            resolver.openOutputStream(image)!!.use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }
            // The checked receipt can settle a saved attempt without resending.
            val recovered = TeamCommentModel(restarted, target, "Fictional shared chat") { method, _ ->
                assertEquals("teams.connection.call", method)
                buildJsonObject { put("receipt", buildJsonObject {
                    put("shareId", target.share); put("clientMessageId", restarted.load(target)!!.attempt!!.id)
                    put("state", "accepted"); put("sequence", 0); put("acceptedAtMs", 1)
                }) }
            }
            runBlocking { recovered.restore(); recovered.check() }
            assertNull(restarted.load(target)); assertEquals("", recovered.text)
        } finally { directory.deleteRecursively() }
    }
    @Test fun localRecoveryWorksOfflineAndRemovalRequiresTheReviewedVersion() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.noBackupFilesDir, "team-comment-test-" + UUID.randomUUID())
        val storage = TeamCommentDraftStore(directory)
        try {
            storage.save(target, "Fictional offline writing\n".repeat(100), null, "Fictional shared chat on a computer")
            compose.setContent {
                TsTheme(DarkColors) {
                    MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                        Surface(Modifier.fillMaxSize().safeDrawingPadding()) {
                            TeamCommentRecoveryList(storage, target.origin, target.person) {}
                        }
                    }
                }
            }
            compose.waitUntil(5_000) { compose.onAllNodesWithText("Fictional shared chat on a computer").fetchSemanticsNodes().size == 1 }
            compose.onNodeWithText(L10n.text("common.teams.copy_draft")).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText(L10n.text("common.teams.remove_local_draft")).performScrollTo().performClick()
            compose.onNodeWithText(L10n.text("common.teams.remove_draft")).assertIsDisplayed()
            // Another writer changes the reviewed version while confirmation
            // is open. The stale removal must preserve those new words.
            val before = storage.load(target)!!
            val newer = storage.save(target, "Newer fictional words", before, "Fictional shared chat on a computer")
            compose.onNodeWithText(L10n.text("common.teams.remove_draft")).performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithText(L10n.text("common.teams.comment_draft_changed")).fetchSemanticsNodes().isNotEmpty() }
            assertEquals(newer, storage.load(target))
        } finally { directory.deleteRecursively() }
    }

}
