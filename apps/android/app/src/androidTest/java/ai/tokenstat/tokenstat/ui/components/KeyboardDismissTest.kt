// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.content.ContentValues
import android.graphics.Bitmap
import android.provider.MediaStore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardDismissTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val keyboardVisible = AtomicBoolean()
    private val submitted = AtomicInteger()
    private var showKeyboard: (() -> Unit)? = null
    private val hide get() = L10n.text("android.terminalscreen.hide_keyboard.f6b0718e")

    private fun show(form: Boolean) {
        compose.runOnUiThread {
            compose.activity.enableEdgeToEdge()
            compose.activity.window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    var value by remember { mutableStateOf("") }
                    if (form) {
                        TsModalScreen(title = "Keyboard QA", onDismiss = {}) {
                            observeKeyboard()
                            OutlinedTextField(value, { value = it },
                                modifier = Modifier.testTag("keyboard-field"),
                                label = { Text("Code") }, singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                keyboardActions = KeyboardActions(onDone = { submitted.incrementAndGet() }))
                        }
                    } else {
                        Surface(Modifier.fillMaxSize()) {
                            Column(Modifier.padding(16.dp)) {
                                observeKeyboard()
                                TsSearchField("Search", value, { value = it },
                                    onSubmit = { submitted.incrementAndGet() })
                            }
                        }
                    }
                }
            }
        }
    }

    @Composable private fun observeKeyboard() {
        val visible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
        val keyboard = LocalSoftwareKeyboardController.current
        SideEffect {
            keyboardVisible.set(visible)
            showKeyboard = { keyboard?.show() }
        }
    }

    private fun captureKeyboard(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = instrumentation.uiAutomation.takeScreenshot() ?: error("No keyboard screenshot")
        val resolver = instrumentation.targetContext.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/tokenstat-keyboard-qa")
        }) ?: error("Cannot save keyboard screenshot")
        resolver.openOutputStream(uri)!!.use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun dismissAndKeepText(field: SemanticsNodeInteraction, text: String, screenshot: String) {
        compose.onNodeWithContentDescription(hide).assertDoesNotExist()
        // A semantic click only requests focus; a touch opens the real IME.
        field.performTouchInput { click() }.performTextInput(text)
        compose.waitForIdle()
        compose.runOnIdle { showKeyboard?.invoke() }
        try {
            compose.waitUntil(10_000) {
                keyboardVisible.get() && compose.onAllNodesWithContentDescription(hide).fetchSemanticsNodes().isNotEmpty()
            }
        } catch (error: Throwable) {
            captureKeyboard("$screenshot-failed")
            throw AssertionError("IME visible=${keyboardVisible.get()}: " + compose.onAllNodes(isRoot()).fetchSemanticsNodes().size + " roots", error)
        }
        captureKeyboard(screenshot)
        compose.onNodeWithContentDescription(hide).assertIsDisplayed().performClick()
        compose.waitUntil(10_000) {
            !keyboardVisible.get() && compose.onAllNodesWithContentDescription(hide).fetchSemanticsNodes().isEmpty()
        }
        field.assertTextContains(text)
        assertEquals(0, submitted.get())
    }

    @Test fun searchKeyboardCanHideWithoutClearingOrSubmitting() {
        show(form = false)
        dismissAndKeepText(compose.onNode(hasSetTextAction()), "routing", "android-search-keyboard")
    }

    @Test fun numericFormKeyboardCanHideWithoutClosingTheForm() {
        show(form = true)
        dismissAndKeepText(compose.onNodeWithTag("keyboard-field"), "12345", "android-numeric-keyboard")
        compose.onNodeWithText("Keyboard QA").assertIsDisplayed()
    }
}
