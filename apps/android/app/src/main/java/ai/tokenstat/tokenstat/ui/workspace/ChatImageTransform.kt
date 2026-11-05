// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Coordinates stay in the viewport, independent of the image's graphics layer. */
internal data class ChatImageTransform(val scale: Float = 1f, val offset: Offset = Offset.Zero) {
    fun zoomedTo(next: Float, anchor: Offset, pan: Offset, viewport: Size, image: Size): ChatImageTransform {
        if (!next.isFinite() || !anchor.x.isFinite() || !anchor.y.isFinite() || !pan.x.isFinite() || !pan.y.isFinite()) return this
        val zoom = next.coerceIn(1f, 5f)
        val pivot = anchor - Offset(viewport.width / 2, viewport.height / 2)
        val ratio = zoom / scale
        return ChatImageTransform(zoom, offset * ratio + pivot * (1 - ratio) + pan).constrained(viewport, image)
    }

    fun constrained(viewport: Size, image: Size): ChatImageTransform {
        if (viewport.width <= 0 || viewport.height <= 0 || !viewport.width.isFinite() || !viewport.height.isFinite())
            return copy(offset = Offset.Zero)
        val fitted = if (image.width > 0 && image.height > 0 && image.width.isFinite() && image.height.isFinite()) {
            val factor = min(viewport.width / image.width, viewport.height / image.height)
            Size(image.width * factor, image.height * factor)
        } else viewport
        val limitX = max(0f, (fitted.width * scale - viewport.width) / 2)
        val limitY = max(0f, (fitted.height * scale - viewport.height) / 2)
        return copy(offset = Offset(offset.x.coerceIn(-limitX, limitX), offset.y.coerceIn(-limitY, limitY)))
    }
}

internal fun chatImageSwipeDirection(startScale: Float, endScale: Float, multiplePointers: Boolean, distance: Offset,
                                    width: Float, minimumDistance: Float): Int {
    if (startScale > 1.001f || endScale > 1.001f || multiplePointers || !distance.x.isFinite() || !distance.y.isFinite()) return 0
    if (abs(distance.x) < max(minimumDistance, width * .18f) || abs(distance.x) < abs(distance.y) * 1.3f) return 0
    return if (distance.x < 0) 1 else -1
}
