// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.*
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.activity.ComponentActivity
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ChatImageGestureTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var file: File
    private val selection = mutableIntStateOf(0)
    private fun viewport() = compose.onNodeWithTag("chat-image-viewport")
    @Before fun prepare() {
        file = File.createTempFile("gesture-", ".png", InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(android.graphics.Color.WHITE)
        canvas.drawRect(140f, 190f, 160f, 210f, Paint().apply { color = android.graphics.Color.RED })
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        compose.setContent {
            TsTheme(DarkColors) {
                MaterialTheme(colorScheme = DarkColors.toColorScheme(), typography = TsType.typography) {
                    val index = selection.intValue
                    ChatImageViewer(ChatDisplayItem.Attachment("row-$index", "image-$index", "gesture-image", "image/png", file.length()),
                        index, 3, file, false, null,
                        onPrevious = { selection.intValue = (selection.intValue - 1).coerceAtLeast(0) },
                        onNext = { selection.intValue = (selection.intValue + 1).coerceAtMost(2) },
                        onDismiss = {}, onLoad = {}, onOpen = {}, onSave = {})
                }
            }
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("gesture-image").fetchSemanticsNodes().isNotEmpty() }
    }
    @After fun clean() { file.delete() }
    private fun marker(): Offset {
        val pixels = viewport().captureToImage().toPixelMap()
        var xTotal = 0.0; var yTotal = 0.0; var count = 0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            val c = pixels[x, y]
            if (c.red > .8f && c.green < .2f && c.blue < .2f) { xTotal += x; yTotal += y; count++ }
        }
        assertTrue("The focal marker must remain visible", count > 8)
        return Offset((xTotal / count).toFloat(), (yTotal / count).toFloat())
    }
    private fun anchored(before: Offset, after: Offset) {
        assertTrue("Zoom moved the focal point from $before to $after", abs(before.x - after.x) < 8 && abs(before.y - after.y) < 8)
    }
    @Test fun pinchKeepsItsFocalPoint() {
        val point = marker()
        viewport().performTouchInput {
            pinch(start0 = point + Offset(-25f, 0f), end0 = point + Offset(-60f, 0f),
                start1 = point + Offset(25f, 0f), end1 = point + Offset(60f, 0f), durationMillis = 600)
        }
        compose.onNodeWithText("100%").assertDoesNotExist()
        anchored(point, marker())
        assertEquals(0, selection.intValue)
    }
    @Test fun doubleTapZoomsAroundTheTappedPoint() {
        val point = marker()
        viewport().performTouchInput { doubleClick(point) }
        anchored(point, marker())
    }
    @Test fun fittedImagesSwipeAndZoomedImagesPan() {
        viewport().performTouchInput { swipeLeft() }
        compose.waitForIdle(); assertEquals("A fitted image should swipe to the next image", 1, selection.intValue)
        compose.onNodeWithContentDescription(L10n.text("common.chat.images.zoom_in")).performClick()
        viewport().performTouchInput { swipeLeft() }
        compose.waitForIdle(); assertEquals("A zoomed image should pan without changing selection", 1, selection.intValue)
        compose.onNodeWithContentDescription(L10n.text("common.chat.images.reset_zoom")).performClick()
        viewport().performTouchInput { swipeRight() }
        compose.waitForIdle(); assertEquals("Resetting zoom should restore swipe navigation", 0, selection.intValue)
    }
    @Test fun pinchingBackToFitRestoresSwipingWithoutChangingImageMidGesture() {
        viewport().performTouchInput { doubleClick(center) }
        compose.onNodeWithText("100%").assertDoesNotExist()
        viewport().performTouchInput {
            val point = center
            pinch(start0 = point + Offset(-140f, 0f), end0 = point + Offset(-280f, 0f),
                start1 = point + Offset(140f, 0f), end1 = point + Offset(-220f, 0f), durationMillis = 600)
        }
        compose.onNodeWithText("100%").assertIsDisplayed()
        assertEquals("A pinch ending at fitted size must not also navigate", 0, selection.intValue)
        viewport().performTouchInput { swipeLeft() }
        compose.waitForIdle(); assertEquals(1, selection.intValue)
    }
    @Test fun panningUsesImageBoundsInsteadOfEmptyLetterboxSpace() {
        compose.onNodeWithContentDescription(L10n.text("common.chat.images.zoom_in")).performClick()
        val before = marker()
        viewport().performTouchInput { swipe(center, center + Offset(80f, 150f), 500) }
        val after = marker()
        assertTrue("Horizontal pan should move the image", after.x > before.x + 40)
        assertTrue("A short image should remain vertically centered", abs(after.y - before.y) < 8)
        assertEquals(0, selection.intValue)
    }

}
