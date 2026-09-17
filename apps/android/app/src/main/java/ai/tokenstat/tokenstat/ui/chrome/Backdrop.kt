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

/// Real frosted glass, without a library.
///
/// `Modifier.blur` blurs a composable's own content, never what is behind it,
/// so it cannot draw a bar you see the screen through. This records the
/// content once into a layer, keeps a blurred copy of that layer, and lets a
/// sibling draw the copy inside its own shape. That is a backdrop filter:
/// what passes under the bar arrives as a wash rather than as readable text.
///
/// Before the tab bar had this it was `panel` at 0.75 alpha and nothing else,
/// which left list rows legible straight through the dock. Plain transparency
/// reads as a mistake; a blur reads as a material.
///
/// A blur needs `RenderEffect`, which is API 31. Below that `supported` is
/// false, nothing is drawn, and callers fall back to an honest solid surface.
/// A translucent bar you can read through is worse than an opaque one.
@Stable
class Backdrop internal constructor(
    internal val source: GraphicsLayer,
    internal val blurred: GraphicsLayer,
    internal val radius: Dp,
) {
    /// Where the recorded content sits, so a sampler can line its own bounds
    /// up with the right part of the picture.
    internal var origin by mutableStateOf(Offset.Zero)

    val supported: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
}

/// One backdrop per screen that wants one. The radius is the blur's sigma in
/// dp, near what the iOS system materials use under a floating bar.
@Composable
fun rememberBackdrop(radius: Dp = 20.dp): Backdrop {
    val source = rememberGraphicsLayer()
    val blurred = rememberGraphicsLayer()
    return remember(source, blurred, radius) { Backdrop(source, blurred, radius) }
}

/// Mark the content a backdrop samples.
///
/// Put this on the content, never on an ancestor that also holds the bar:
/// recording a layer that contains the sampler would feed the blur its own
/// output, one frame behind, forever.
fun Modifier.backdropSource(backdrop: Backdrop): Modifier = this
    .onGloballyPositioned { backdrop.origin = it.positionInRoot() }
    .drawWithContent {
        if (!backdrop.supported) {
            drawContent()
            return@drawWithContent
        }
        // Recorded once, drawn twice: sharp for the screen, blurred for
        // whatever samples it. The blur lives on the copy so the content
        // itself stays crisp.
        backdrop.source.record { this@drawWithContent.drawContent() }
        drawLayer(backdrop.source)
        val sigma = backdrop.radius.toPx()
        // Decal, not Clamp: Clamp smears the screen's edge pixels outward, so
        // a bar near the bottom picks up a streak of whatever the last row
        // happened to be.
        backdrop.blurred.renderEffect = BlurEffect(sigma, sigma, TileMode.Decal)
        backdrop.blurred.record { drawLayer(backdrop.source) }
    }

/// Draw the blurred backdrop inside this composable's own shape.
///
/// The translation is the difference between where the content was recorded
/// and where this sits, so the wash under the bar is the part of the screen
/// the bar actually covers rather than the top-left corner of it.
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
