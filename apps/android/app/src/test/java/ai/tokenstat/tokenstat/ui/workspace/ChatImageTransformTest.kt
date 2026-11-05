// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import org.junit.Assert.*
import org.junit.Test

class ChatImageTransformTest {
    private val viewport = Size(600f, 400f)
    private fun close(expected: Offset, actual: Offset) {
        assertEquals(expected.x, actual.x, .001f); assertEquals(expected.y, actual.y, .001f)
    }
    @Test fun repeatedZoomKeepsTheImagePointUnderTheFingers() {
        val anchor = Offset(170f, 220f)
        val center = Offset(300f, 200f)
        var state = ChatImageTransform()
        val pixel = anchor - center
        for (scale in listOf(1.1f, 1.5f, 2f, 3f, 4.5f, 2f, 1f)) {
            state = state.zoomedTo(scale, anchor, Offset.Zero, viewport, viewport)
            close(anchor, center + state.offset + pixel * state.scale)
        }
    }
    @Test fun pinchTranslationAndOneFingerPanningUseViewportCoordinates() {
        val state = ChatImageTransform(2f, Offset(30f, -20f))
        val anchor = Offset(250f, 170f)
        val pan = Offset(17f, 11f)
        val pixel = (anchor - Offset(300f, 200f) - state.offset) / state.scale
        val next = state.zoomedTo(3f, anchor, pan, viewport, viewport)
        close(anchor + pan, Offset(300f, 200f) + next.offset + pixel * next.scale)
        close(next.offset + pan, next.zoomedTo(3f, anchor, pan, viewport, viewport).offset)
    }
    @Test fun panBoundsUseTheFittedImageAndResetAtMinimumZoom() {
        val portraitViewport = Size(400f, 800f)
        val wideImage = Size(1000f, 500f)
        val wide = ChatImageTransform(2f, Offset(999f, 999f)).constrained(portraitViewport, wideImage)
        close(Offset(200f, 0f), wide.offset)
        val tall = ChatImageTransform(2f, Offset(999f, 999f)).constrained(Size(800f, 400f), Size(500f, 1000f))
        close(Offset(0f, 200f), tall.offset)
        val reset = wide.zoomedTo(1f, Offset(100f, 400f), Offset.Zero, portraitViewport, wideImage)
        close(Offset.Zero, reset.offset)
        close(Offset.Zero, ChatImageTransform(1f, Offset(500f, 500f)).constrained(viewport, viewport).offset)
    }
    @Test fun zoomLimitsAndNonfiniteGestureValuesCannotCorruptTheView() {
        val state = ChatImageTransform()
        assertEquals(5f, state.zoomedTo(20f, Offset(300f, 200f), Offset.Zero, viewport, viewport).scale)
        assertEquals(1f, state.zoomedTo(-3f, Offset.Zero, Offset.Zero, viewport, viewport).scale)
        assertEquals(state, state.zoomedTo(Float.NaN, Offset.Zero, Offset.Zero, viewport, viewport))
        assertEquals(state, state.zoomedTo(2f, Offset.Unspecified, Offset.Zero, viewport, viewport))
        assertEquals(state, state.zoomedTo(2f, Offset.Zero, Offset(Float.POSITIVE_INFINITY, 0f), viewport, viewport))
    }
    @Test fun onlyFittedSinglePointerHorizontalSwipesChangeImages() {
        fun direction(start: Float = 1f, end: Float = 1f, multi: Boolean = false, delta: Offset = Offset(-150f, 10f)) =
            chatImageSwipeDirection(start, end, multi, delta, 600f, 48f)
        assertEquals(1, direction())
        assertEquals(-1, direction(delta = Offset(150f, 10f)))
        assertEquals(0, direction(start = 2f)); assertEquals(0, direction(end = 2f))
        assertEquals(0, direction(multi = true)); assertEquals(0, direction(delta = Offset(100f, 0f)))
        assertEquals(0, direction(delta = Offset(150f, 160f)))
        assertEquals(0, direction(delta = Offset.Unspecified))
    }
}
