// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/// The face of a conversation. Port of `PersonaMark`.
///
/// Drawn, not drawn-by-someone: every persona gets a character built from one
/// number, so a new persona has a face the moment it is named and there is no
/// asset to ship, scale, or theme.
///
/// Static for now: the resting idle pose, which is what Reduce Motion shows on
/// the client too. The full soft-body motion (springs, moods, motes) is a
/// follow-up; nothing here precludes it, the engine would feed the same draw
/// pass its body each frame.
@Composable
fun PersonaMark(seed: ULong, size: Dp = 28.dp, modifier: Modifier = Modifier) {
    val colors = LocalTsColors.current
    val traits = remember(seed) { PersonaTraits(seed) }
    val hue = traits.hue(colors.accent, colors.secondary)
    Canvas(modifier.size(size)) {
        drawPersonaFace(traits, hue)
    }
}

/// Everything a resting persona looks like, drawn in one pass. Port of the
/// `PersonaRenderer` body, shadow, antenna, highlight and idle face, over the
/// resting body the soft body settles into. Shared with the chat empty art so
/// the placeholder and the mark are the same creature.
fun DrawScope.drawPersonaFace(traits: PersonaTraits, hue: Color) {
    val unit = min(size.width, size.height)
    if (unit <= 1f) return
    val w = size.width
    val h = size.height

    // Resting nodes: the reach in `PersonaSoftBody` is the radius widened by
    // each lump, which is where a settled body sits.
    val count = traits.lumps.size
    val cx = 0.5f
    val cy = 0.95f - 0.355f
    val nodes = (0 until count).map { index ->
        val angle = index.toFloat() * 2f * PI.toFloat() / count.toFloat()
        val reach = 0.355f * (1f + traits.lumps[index] * 0.10f)
        Offset(cx + cos(angle) * reach, cy + sin(angle) * reach)
    }
    // The outline smoothing from `PersonaSoftBody.outline`, then the same
    // Catmull-Rom to Bezier closed curve.
    val smoothing = 0.34f
    val points = (0 until count).map { index ->
        val prev = nodes[(index + count - 1) % count]
        val cur = nodes[index]
        val next = nodes[(index + 1) % count]
        Offset(
            cur.x + ((prev.x + next.x) * 0.5f - cur.x) * smoothing,
            cur.y + ((prev.y + next.y) * 0.5f - cur.y) * smoothing,
        )
    }
    val outline = Path().apply {
        moveTo(points[0].x * w, points[0].y * h)
        for (index in 0 until count) {
            val p0 = points[(index + count - 1) % count]
            val p1 = points[index]
            val p2 = points[(index + 1) % count]
            val p3 = points[(index + 2) % count]
            cubicTo(
                (p1.x + (p2.x - p0.x) / 6f) * w, (p1.y + (p2.y - p0.y) / 6f) * h,
                (p2.x - (p3.x - p1.x) / 6f) * w, (p2.y - (p3.y - p1.y) / 6f) * h,
                p2.x * w, p2.y * h,
            )
        }
        close()
    }
    val minX = nodes.minOf { it.x }
    val maxX = nodes.maxOf { it.x }
    val minY = nodes.minOf { it.y }
    val maxY = nodes.maxOf { it.y }
    val midX = (minX + maxX) / 2f
    val centroid = Offset(nodes.sumOf { it.x.toDouble() }.toFloat() / count, nodes.sumOf { it.y.toDouble() }.toFloat() / count)
    val crown = nodes.minByOrNull { it.y } ?: centroid

    // Contact shadow: it shrinks and fades as the body leaves the ground.
    val air = max(0f, 0.95f - maxY)
    val closeness = max(0.30f, 1f - air * 2.6f)
    val shadowW = (maxX - minX) * w * 0.80f * closeness
    val shadowH = unit * 0.052f * closeness
    drawOval(
        hue.copy(alpha = 0.20f * closeness),
        Offset(w / 2f - shadowW / 2f, 0.95f * h - shadowH * 0.35f),
        Size(shadowW, shadowH),
    )

    if (traits.hasAntenna && unit >= 18f) {
        // Rooted in the crown node, so it whips with the squash instead of
        // floating over a rectangle the body no longer fills.
        val root = Offset(crown.x * w, crown.y * h)
        val lean = (crown.x - centroid.x) * w
        val tip = Offset(root.x + unit * 0.06f + lean * 1.6f, root.y - unit * 0.15f)
        val stalk = Path().apply {
            moveTo(root.x, root.y + unit * 0.02f)
            quadraticTo(root.x + unit * 0.09f + lean, root.y - unit * 0.05f, tip.x, tip.y)
        }
        drawPath(stalk, hue.copy(alpha = 0.75f), style = Stroke(width = max(1f, unit * 0.032f)))
        val dotR = unit * 0.045f
        drawOval(hue, Offset(tip.x - dotR, tip.y - dotR), Size(dotR * 2f, dotR * 2f))
    }

    drawPath(
        outline,
        Brush.linearGradient(
            0.0f to hue.copy(alpha = 0.20f),
            1.0f to hue.copy(alpha = 0.38f),
            start = Offset(w / 2f, minY * h),
            end = Offset(w / 2f, maxY * h),
        ),
    )
    drawPath(outline, hue.copy(alpha = 0.92f), style = Stroke(width = max(1f, unit * 0.036f)))

    clipPath(outline) {
        // The highlight sits off the middle rather than off the bounding box,
        // so a squash slides it across the body instead of pinning it to a
        // corner. A soft gradient rather than a flat ellipse: at 26% white a
        // hard edge reads as a scuff instead of light.
        val hlW = (maxX - minX) * w * 0.155f
        val hlH = (maxY - minY) * h * 0.085f
        val hlX = midX * w - hlW * 1.55f
        val hlY = (minY + (maxY - minY) * 0.17f) * h
        rotate(-28.65f, Offset(hlX + hlW / 2f, hlY + hlH / 2f)) {
            drawOval(
                Brush.radialGradient(
                    0.0f to Color.White.copy(alpha = 0.26f),
                    1.0f to Color.White.copy(alpha = 0f),
                    center = Offset(hlX + hlW / 2f, hlY + hlH / 2f),
                    radius = max(hlW, hlH) * 0.62f,
                ),
                Offset(hlX, hlY),
                Size(hlW, hlH),
            )
        }
        drawPersonaIdleFace(traits, hue, minX, maxX, minY, maxY, centroid, crown, unit)
    }
}

/// The resting idle face: gaze level, the persona's own mouth as a bias on a
/// mild smile. Both clipped to the body by the caller, so a heavy squash
/// pushes them around inside the creature rather than letting an eye escape.
private fun DrawScope.drawPersonaIdleFace(
    traits: PersonaTraits,
    ink: Color,
    minX: Float,
    maxX: Float,
    minY: Float,
    maxY: Float,
    centroid: Offset,
    crown: Offset,
    unit: Float,
) {
    val w = size.width
    val h = size.height
    // The face borrows the body's own squash: wide and flat means narrow eyes
    // further apart, tall and thin means round eyes closer together.
    val aspect = ((maxY - minY) / max(maxX - minX, 1e-4f)).coerceIn(0.45f, 1.7f)
    // Lean, taken from where the crown sits relative to the middle.
    val tilt = atan2(crown.x - centroid.x, max(centroid.y - crown.y, 1e-4f)) * 0.75f
    val heightPoints = (maxY - minY) * h
    val anchorHeight = heightPoints * 0.10f
    val origin = Offset(centroid.x * w, centroid.y * h)
    fun place(dx: Float, dy: Float): Offset = Offset(
        origin.x + dx * cos(tilt) - dy * sin(tilt),
        origin.y + dx * sin(tilt) + dy * cos(tilt),
    )

    val count = traits.eyeCount
    // Small marks need proportionally bigger features or the face turns into
    // two specks. Three fixed steps, not a curve.
    val lod = if (unit < 24f) 1.35f else if (unit < 34f) 1.15f else 1.0f
    val radius = unit * (if (count == 1) 0.115f else if (count == 2) 0.082f else 0.065f) * lod
    val spread = radius * (if (count == 2) 2.9f else 2.6f) / max(sqrt(aspect), 0.6f)
    val openness = max(0.02f, aspect)
    for (index in 0 until count) {
        val offset = index.toFloat() - (count - 1).toFloat() / 2f
        val centre = place(offset * spread, -anchorHeight)
        val frame = Size(radius * 2f, max(radius * 0.10f, radius * 2f * openness))
        val topLeft = Offset(centre.x - radius, centre.y - radius * openness)
        when (traits.eyeShape) {
            PersonaTraits.EyeShape.PIXEL ->
                drawRoundRect(ink, topLeft, frame, CornerRadius(radius * 0.32f, radius * 0.32f))
            PersonaTraits.EyeShape.OVAL ->
                drawOval(ink, Offset(topLeft.x + radius * 0.22f, topLeft.y), Size(frame.width - radius * 0.44f, frame.height))
            PersonaTraits.EyeShape.ROUND -> drawOval(ink, topLeft, frame)
        }
    }

    if (unit < 21f) return
    // The persona's own mouth is a bias on the mood's, not a replacement: a
    // naturally glum character still smiles when it wins, just less widely.
    val resting = when (traits.mouth) {
        PersonaTraits.Mouth.SMILE -> 0.34f
        PersonaTraits.Mouth.FROWN -> -0.34f
        PersonaTraits.Mouth.FLAT -> -0.10f
        PersonaTraits.Mouth.DOT, null -> 0f
    }
    val curve = (0.45f + resting).coerceIn(-1.1f, 1.1f)
    val half = unit * 0.078f * traits.mouthWidth
    val baseY = -anchorHeight + radius * 2.15f
    val left = place(-half, baseY)
    val right = place(half, baseY)
    val bow = place(0f, baseY + curve * unit * 0.142f)
    val mouth = Path().apply {
        moveTo(left.x, left.y)
        quadraticTo(bow.x, bow.y, right.x, right.y)
    }
    drawPath(mouth, ink.copy(alpha = 0.78f), style = Stroke(width = max(1f, unit * 0.038f)))
}
