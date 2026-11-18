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
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RoutingLimitCardTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun chat(wait: Boolean) = buildJsonObject {
        put("id", "qa-limit")
        put("backend", "grok")
        put("sendRevision", 3)
        put("routing", buildJsonObject {
            put("policy", buildJsonObject {
                put("enabled", false)
                put("waitForReset", wait)
            })
            put("limit", buildJsonObject {
                put("kind", "usage")
                put("provider", "grok")
                put("reason", "You have reached your usage limit.")
                put("resetsAtMs", System.currentTimeMillis() + 59 * 60_000L)
            })
            put("waiting", wait)
            put("needsDeliveryCheck", false)
        })
    }

    private val backends = listOf(
        buildJsonObject { put("id", "grok"); put("label", "Grok") },
        buildJsonObject { put("id", "codex"); put("label", "Codex") },
    )

    @Test fun answersTheTapBeforeTheHostAndHandsOff() {
        var colors: TsColors by mutableStateOf(DarkColors)
        var current by mutableStateOf(chat(false))
        val reply = CompletableDeferred<JsonElement>()
        val refresh = CompletableDeferred<Unit>()
        var sent: JsonObject? = null
        var handedOff = false
        compose.setContent {
            TsTheme(colors) {
                MaterialTheme(colorScheme = colors.toColorScheme(), typography = TsType.typography) {
                    Column(Modifier.fillMaxWidth().background(colors.background).padding(16.dp)) {
                        ChatRoutingControls(
                            chat = current,
                            backends = backends,
                            call = { _, params -> sent = params; reply.await() },
                            onChanged = { refresh.await(); current = chat(true) },
                            showSection = false,
                            onHandOff = { handedOff = true },
                        )
                    }
                }
            }
        }
        compose.onNodeWithText("Grok usage limit reached").assertExists()
        save("limit-dark")
        compose.onNodeWithText("Continue when this limit resets").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Continue when this limit resets")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ToggleableState, ToggleableState.On))
        save("limit-dark-pending")
        assertEquals(JsonPrimitive(true), (sent?.get("routing") as? JsonObject)?.get("waitForReset"))
        reply.complete(JsonObject(emptyMap()))
        compose.waitForIdle()
        compose.onNodeWithText("Continue when this limit resets")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ToggleableState, ToggleableState.On))
        refresh.complete(Unit)
        compose.waitForIdle()
        colors = LightColors
        compose.waitForIdle()
        save("limit-light-checked")
        compose.onNodeWithText("Hand off now").performClick()
        assertEquals(true, handedOff)
    }

    private fun save(name: String) {
        compose.waitForIdle()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val folder = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir("qa") ?: return
        File(folder, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
