// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.DarkColors
import ai.tokenstat.tokenstat.ui.theme.LightColors
import ai.tokenstat.tokenstat.ui.theme.TsColors
import ai.tokenstat.tokenstat.ui.theme.TsTheme
import ai.tokenstat.tokenstat.ui.theme.toColorScheme
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TranscriptHandoffBannerTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun showsTheAgentAndDisclosesTheSummary() {
        var colors: TsColors by mutableStateOf(LightColors)
        compose.setContent {
            TsTheme(colors) {
                MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
                    Column(Modifier.fillMaxWidth().background(colors.background).padding(16.dp)) {
                        TranscriptHandoffBanner(to = "Grok", brief = "Codex reached its usage limit. Continue the list from where it stopped.")
                    }
                }
            }
        }
        compose.onNodeWithText("Handed to Grok").assertExists()
        save("handoff-light")
        compose.onNodeWithText("What it was told").performClick()
        compose.onNodeWithText("Codex reached its usage limit. Continue the list from where it stopped.").assertExists()
        save("handoff-light-open")
        colors = DarkColors
        compose.waitForIdle()
        save("handoff-dark-open")
    }

    private fun save(name: String) {
        compose.waitForIdle()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val folder = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("qa") ?: return
        File(folder, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
