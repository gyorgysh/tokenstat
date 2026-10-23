// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class TeamSharedFileTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val bytes = "Fictional shared document".toByteArray()
    private fun file(id: String = "file") = buildJsonObject { put("id", id); put("name", "../../fictional.txt"); put("mediaType", "text/plain"); put("size", bytes.size) }
    private fun reply(id: String = "file") = buildJsonObject { put("shareId", "share"); put("attachment", file(id)); put("data", Base64.getEncoder().encodeToString(bytes)) }
    private fun screen(content: @androidx.compose.runtime.Composable () -> Unit) {
        compose.setContent { TsTheme(DarkColors) { MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) { Surface(Modifier.fillMaxSize().safeDrawingPadding()) { content() } } } }
    }
    @Test fun aNonImageFileExportsOnlyAfterExplicitSaveAndRejectsAForeignReply() {
        val exported = CopyOnWriteArrayList<TeamSharedFileData>(); var reads = 0
        screen { Column { SharedFile(file(), fetch = { reads++; reply(if (reads == 1) "file" else "another-file") }, saveOverride = { exported += it }) } }
        compose.waitForIdle(); assertEquals(0, reads); assertTrue(exported.isEmpty())
        compose.onNodeWithText("fictional.txt").assertExists()
        compose.onNodeWithText(L10n.text("common.teams.save_file")).assertIsEnabled().performClick()
        compose.waitUntil(5_000) { exported.size == 1 }
        assertEquals("fictional.txt", exported.single().name); assertArrayEquals(bytes, exported.single().bytes)
        compose.onNodeWithText(L10n.text("common.teams.save_file")).performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText(L10n.text("common.teams.file_save_failed")).fetchSemanticsNodes().size == 1 }
        assertEquals(1, exported.size)
    }
    @Test fun aDownloadCannotSaveAfterItsAccountBoundViewIsRemoved() {
        val shown = mutableStateOf(true); val pending = CompletableDeferred<JsonObject>(); val entered = CompletableDeferred<Unit>()
        val exported = CopyOnWriteArrayList<TeamSharedFileData>()
        screen { Column { if (shown.value) SharedFile(file(), fetch = { entered.complete(Unit); pending.await() }, saveOverride = { exported += it }) else Text("Fictional view closed") } }
        compose.onNodeWithText(L10n.text("common.teams.save_file")).performClick()
        compose.waitUntil(5_000) { entered.isCompleted }
        compose.runOnIdle { shown.value = false }
        pending.complete(reply()); compose.waitForIdle()
        compose.onNodeWithText("Fictional view closed").assertExists(); assertTrue(exported.isEmpty())
    }
}
