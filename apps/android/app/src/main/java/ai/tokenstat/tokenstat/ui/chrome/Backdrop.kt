// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

@Stable
class Backdrop internal constructor(
    internal val source: GraphicsLayer,
    internal val blurred: GraphicsLayer,
    internal val radius: Dp,
) {
    internal var origin by mutableStateOf(Offset.Zero)

    val supported: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
}

@Composable
fun rememberBackdrop(radius: Dp = 20.dp): Backdrop {
    val source = rememberGraphicsLayer()
    val blurred = rememberGraphicsLayer()
    return remember(source, blurred, radius) { Backdrop(source, blurred, radius) }
}

fun Modifier.backdropSource(backdrop: Backdrop): Modifier = this
    .onGloballyPositioned { backdrop.origin = it.positionInRoot() }
    .drawWithContent {
        if (!backdrop.supported) {
            drawContent()
            return@drawWithContent
        }
        backdrop.source.record { this@drawWithContent.drawContent() }
        drawLayer(backdrop.source)
        val sigma = backdrop.radius.toPx()
        backdrop.blurred.renderEffect = BlurEffect(sigma, sigma, TileMode.Decal)
        backdrop.blurred.record { drawLayer(backdrop.source) }
    }

fun Modifier.backdropBlur(backdrop: Backdrop, shape: Shape): Modifier = composed {
    var here by remember { mutableStateOf(Offset.Zero) }
    Modifier
        .onGloballyPositioned { here = it.positionInRoot() }
        .drawBehind {
            if (!backdrop.supported) return@drawBehind
            val path = Path().apply { addOutline(shape.createOutline(size, layoutDirection, this@drawBehind)) }
            clipPath(path) {
                translate(backdrop.origin.x - here.x, backdrop.origin.y - here.y) {
                    drawLayer(backdrop.blurred)
                }
            }
        }
}
