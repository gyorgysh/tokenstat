// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import android.content.ContentValues
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Production controls with controlled replies; no real provider or account is used. */
@RunWith(AndroidJUnit4::class)
class ChatRoutingTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val calls = CopyOnWriteArrayList<JsonObject>()

    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject

    private fun text(key: String) = L10n.text(key)

    private val backends =
        listOf(
            obj(
                """{"id":"codex","label":"Codex","installed":true,"models":["gpt-6.1-sol"],"efforts":["low","high"]}"""
            ),
            obj("""{"id":"muse","label":"Muse","installed":true,"models":[],"efforts":[]}"""),
        )

    private fun show(policy: JsonObject, limit: JsonObject? = null, shortcut: Boolean = false) {
        val state = buildJsonObject {
            put("policy", policy)
            put("limit", limit ?: JsonNull)
            put("waiting", false)
            put("needsDeliveryCheck", false)
            put("activity", JsonArray(emptyList()))
        }
        val chat = buildJsonObject {
            put("id", "routing-preview")
            put("backend", "codex")
            put("autonomy", "standard")
            put("sendRevision", 1)
            put("running", false)
            put("routing", state)
        }
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(
                    colorScheme = DarkColors.toColorScheme(),
                    typography = TsType.typography,
                ) {
                    Surface(Modifier.fillMaxSize()) {
                        Column(Modifier.padding(16.dp)) {
                            ChatRoutingControls(
                                chat,
                                backends,
                                { method, params ->
                                    when (method) {
                                        "protocol" -> obj("""{"protocol":34}""")
                                        "chat.routing" -> {
                                            if (params["routing"] != null) calls.add(params)
                                            state
                                        }
                                        else -> error("Unexpected call $method")
                                    }
                                },
                                {},
                                showNotice = !shortcut,
                                showSection = !shortcut,
                                showShortcut = shortcut,
                            )
                        }
                    }
                }
            }
        }
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // Capture the initial rendered activity directly to avoid its blank
        // startup frame. Modal sheets use a separate window, so capture the
        // composed system surface once their controls have been asserted.
        val image =
            if (name == "routing-limit-preview" || name == "routing-section-preview" || name == "routing-shortcut-preview")
                compose.onAllNodes(isRoot()).onLast().captureToImage().asAndroidBitmap()
            else instrumentation.uiAutomation.takeScreenshot() ?: error("No routing screenshot")
        val resolver = instrumentation.targetContext.contentResolver
        val uri =
            resolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-routing-qa")
                },
            ) ?: error("Cannot save routing screenshot")
        resolver.openOutputStream(uri)!!.use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test
    fun composerShortcutOpensRoutingAndPreservesWaitOnlyPolicy() {
        show(obj("""{"enabled":false,"waitForReset":true,"routes":[]}"""), shortcut = true)
        compose.onNodeWithText(text("common.chat_routing")).assertDoesNotExist()
        val shortcut = compose.onNodeWithContentDescription(text("common.chat_routing"))
            .assertIsDisplayed().assertHasClickAction()
        screenshot("routing-shortcut-preview")
        shortcut.performClick()
        compose.onNodeWithText(text("common.save")).assertIsDisplayed().performClick()
        compose.waitUntil { calls.isNotEmpty() }
        val saved = calls.last()["routing"]!!.jsonObject
        assertFalse(saved["enabled"]!!.jsonPrimitive.boolean)
        assertTrue(saved["waitForReset"]!!.jsonPrimitive.boolean)
        assertEquals(1, calls.last()["expectedRevision"]!!.jsonPrimitive.int)
    }

    @Test
    fun limitCheckboxCanWaitWithoutEnablingFallbackRouting() {
        val limit = buildJsonObject {
            put("provider", "codex")
            put("kind", "usage")
            put("reason", "Preview only: a reported usage limit.")
            put("resetsAtMs", System.currentTimeMillis() + 3600000)
        }
        show(obj("""{"enabled":false,"waitForReset":false,"routes":[]}"""), limit)
        compose.onNodeWithText(text("common.chat_route_setup")).assertIsDisplayed()
        screenshot("routing-limit-preview")
        compose.onNodeWithText(text("common.chat_wait_reset")).performClick()
        compose.waitUntil { calls.isNotEmpty() }
        assertFalse(calls.last()["routing"]!!.jsonObject["enabled"]!!.jsonPrimitive.boolean)
        assertTrue(calls.last()["routing"]!!.jsonObject["waitForReset"]!!.jsonPrimitive.boolean)
        assertEquals(1, calls.last()["expectedRevision"]!!.jsonPrimitive.int)
    }

    @Test
    fun routingSheetPreservesCombinedModeAndPerModelEffort() {
        show(
            obj(
                """{"enabled":true,"waitForReset":true,"returnPreferred":true,"preferred":{"backend":"codex","model":"gpt-6.1-sol","effort":"high"},"routes":[{"backend":"codex","model":"gpt-6.1-sol","effort":"high"},{"backend":"muse"}]}"""
            )
        )
        compose.onNodeWithText(text("common.chat_route_combined_mode")).assertIsDisplayed()
        screenshot("routing-section-preview")
        compose.onNodeWithText(text("common.chat_route_setup")).performClick()
        compose.waitUntil {
            compose.onAllNodesWithText("high", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("high").performScrollTo().assertIsDisplayed()
        screenshot("routing-settings-preview")
        compose.onNodeWithText(text("common.chat_wait_reset")).performScrollTo().assertIsDisplayed()
        screenshot("routing-reset-preview")
        compose.onNodeWithText(text("common.save")).performClick()
        compose.waitUntil { calls.isNotEmpty() }
        val saved = calls.last()["routing"]!!.jsonObject
        assertTrue(saved["enabled"]!!.jsonPrimitive.boolean)
        assertTrue(saved["waitForReset"]!!.jsonPrimitive.boolean)
        assertTrue(saved["returnPreferred"]!!.jsonPrimitive.boolean)
        assertEquals(
            "high",
            saved["routes"]!!.jsonArray[0].jsonObject["effort"]!!.jsonPrimitive.content,
        )
        assertEquals("high", saved["preferred"]!!.jsonObject["effort"]!!.jsonPrimitive.content)
    }
}
