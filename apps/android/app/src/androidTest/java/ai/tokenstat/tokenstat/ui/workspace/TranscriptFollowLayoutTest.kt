// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TranscriptFollowLayoutTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun completedTallReplyFollowsItsEnding() {
        var completed by mutableStateOf(false)
        compose.setContent {
            val state = rememberLazyListState()
            LaunchedEffect(completed) { state.scrollToTranscriptEnd() }
            LazyColumn(Modifier.height(300.dp), state = state) {
                item { Text("Earlier conversation") }
                item {
                    Column {
                        repeat(40) { Text("Reply line $it") }
                        Text(if (completed) "Final answer marker" else "Streaming marker")
                    }
                }
                if (!completed) item { Box(Modifier.fillMaxWidth().height(34.dp)) }
                transcriptEnd()
            }
        }
        compose.onNodeWithText("Streaming marker").assertIsDisplayed()
        compose.runOnIdle { completed = true }
        compose.onNodeWithText("Final answer marker").assertIsDisplayed()
    }
}
