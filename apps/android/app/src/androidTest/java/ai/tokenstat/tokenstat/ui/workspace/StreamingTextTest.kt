// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StreamingTextTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun newWordsFadeWithoutDimmingOldWordsOrHoldingBackText() {
        var text by mutableStateOf(AnnotatedString("Old"))
        var now by mutableStateOf(0L)
        compose.mainClock.autoAdvance = false
        compose.setContent {
            StreamingText(text, TextStyle(color = Color.White, fontFamily = FontFamily.Monospace, fontSize = 24.sp),
                Modifier.width(240.dp).background(Color.Black).testTag("stream"), true, nowMillis = { now })
        }
        compose.mainClock.advanceTimeByFrame()
        val before = compose.onNodeWithTag("stream").captureToImage().toPixelMap()
        compose.runOnIdle { now = 1_000; text = AnnotatedString("Old New") }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithTag("stream").assertTextEquals("Old New")
        val arriving = compose.onNodeWithTag("stream").captureToImage().toPixelMap()
        compose.runOnIdle { now = 1_300 }
        compose.mainClock.advanceTimeBy(300)
        val settled = compose.onNodeWithTag("stream").captureToImage().toPixelMap()
        var oldPixels = 0
        var fadedPixels = 0
        for (y in 0 until before.height) for (x in 0 until before.width) {
            if (before[x, y].red > .2f) {
                oldPixels++
                assertEquals("Existing text must stay steady", before[x, y].red, arriving[x, y].red, .02f)
            }
            if (settled[x, y].red - arriving[x, y].red > .2f) fadedPixels++
        }
        assertTrue("The old word must be visible", oldPixels > 10)
        assertTrue("New word pixels must fade to full opacity", fadedPixels > 10)
    }
}
