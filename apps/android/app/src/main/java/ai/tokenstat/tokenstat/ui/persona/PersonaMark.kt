// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.delay
import kotlin.random.Random
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.MotionDurationScale
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
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
/// Simulation runs only while resumed; frame ticks invalidate the Canvas draw
/// pass without recomposing or relaying out its conversation row.
@Composable
fun PersonaMark(seed: ULong, modifier: Modifier = Modifier, size: Dp = 28.dp, mood: PersonaMood = PersonaMood.Idle) {
    val colors = LocalTsColors.current
    val traits = remember(seed) { PersonaTraits(seed) }
    val motion = remember(seed) { PersonaMotion(seed, traits.lumps, traits.firmness.toDouble()) }
    val tick = remember { mutableLongStateOf(0L) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val hue = traits.hue(colors.accent, colors.secondary)
    LaunchedEffect(motion, mood, lifecycle) {
        val durationScale = currentCoroutineContext()[MotionDurationScale]
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { scale ->
                motion.suspendClock()
                if (scale <= 0f) {
                    motion.advance(0.0, mood, moving = false)
                    tick.longValue++
                } else {
                    var lastDraw = 0L
                    try {
                        while (currentCoroutineContext().isActive) {
                            withFrameNanos { frame ->
                                val interval = if (size.value >= 48) 16_000_000L else 32_000_000L
                                if (frame - lastDraw >= interval) {
                                    motion.advance(frame / 1_000_000_000.0 / scale, mood)
                                    lastDraw = frame
                                    tick.longValue++
                                }
                            }
                        }
                    } finally { motion.suspendClock() }
                }
            }
        }
    }
    Canvas(modifier.size(size)) {
        tick.longValue // Read only in draw: no frame-driven recomposition.
        drawPersonaFace(traits, hue, motion)
    }
}

/** A chat with nothing to do alternates quiet moments with short playful activity. */
@Composable
fun PersonaPastime(seed: ULong, modifier: Modifier = Modifier, size: Dp = 84.dp) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var mood by remember(seed) { mutableStateOf(PersonaMood.Idle) }
    LaunchedEffect(seed, lifecycle) {
        val durationScale = currentCoroutineContext()[MotionDurationScale]
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { scale ->
                mood = PersonaMood.Idle
                if (scale > 0f) {
                    val activities = listOf(PersonaMood.Bouncing, PersonaMood.Dancing, PersonaMood.Pacing,
                        PersonaMood.Juggling, PersonaMood.Reading, PersonaMood.Gaming, PersonaMood.Typing,
                        PersonaMood.Sipping, PersonaMood.Sketching, PersonaMood.Stargazing,
                        PersonaMood.Gardening, PersonaMood.Bubbling, PersonaMood.Snacking)
                    var previous: PersonaMood? = null
                    delay(700)
                    while (currentCoroutineContext().isActive) {
                        val choices = activities.filter { it != previous }
                        val next = if (Random.nextFloat() < 0.12f) PersonaMood.Sleeping else choices.random()
                        mood = next
                        previous = next
                        delay(Random.nextLong(5_500, 11_001))
                        mood = PersonaMood.Idle
                        delay(Random.nextLong(2_600, 5_401))
                    }
                }
            }
        }
    }
    PersonaMark(seed = seed, modifier = modifier, size = size, mood = mood)
}

/// Everything a resting persona looks like, drawn in one pass. Port of the
/// `PersonaRenderer` body, shadow, antenna, highlight and idle face, over the
/// resting body the soft body settles into. Shared with the chat empty art so
/// the placeholder and the mark are the same creature.
fun DrawScope.drawPersonaFace(traits: PersonaTraits, hue: Color, motion: PersonaMotion? = null) {
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
        if (motion == null) Offset(cx + cos(angle) * reach, cy + sin(angle) * reach)
        else Offset(motion.x[index].toFloat(), motion.y[index].toFloat())
    }
    // The outline smoothing from `PersonaSoftBody.outline`, then the same
    // Catmull-Rom to Bezier closed curve.
    val smoothing = 0.18f
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
            0.0f to androidx.compose.ui.graphics.lerp(hue, Color.White, 0.34f),
            1.0f to hue,
            start = Offset(w / 2f, minY * h),
            end = Offset(w / 2f, maxY * h),
        ),
    )
    drawPath(outline, hue.copy(alpha = 0.65f), style = Stroke(width = max(0.5f, unit * 0.012f)))

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
        val facing = cos(motion?.yaw ?: 0.0).toFloat()
        if (facing > 0f) {
            val origin = Offset(centroid.x * w, centroid.y * h)
            rotate(((motion?.roll ?: 0.0) * 180 / PI).toFloat(), origin) {
                translate(left = (sin(motion?.yaw ?: 0.0) * (maxX - minX) * w * 0.24).toFloat()) {
                    scale(scaleX = max(0.08f, facing), scaleY = 1f, pivot = origin) {
                        drawPersonaIdleFace(traits, androidx.compose.ui.graphics.lerp(hue, Color.Black, 0.78f).copy(alpha = min(1f, facing * 4)),
                            minX, maxX, minY, maxY, centroid, crown, unit,
                            blink = (motion?.blink ?: 0.0).toFloat(), mood = motion?.mood ?: PersonaMood.Idle,
                            previousMood = motion?.previousMood ?: PersonaMood.Idle,
                            gaze = sin((motion?.lifetime ?: 0.0) * 0.61).toFloat() * 0.65f,
                            expressionProgress = ((motion?.moodAge ?: 1.0) / 0.4).toFloat().coerceIn(0f, 1f))
                    }
                }
            }
        }
    }
    if (motion != null && unit / density >= 40f) {
        val entering = ((motion.moodAge - 0.18) / 0.35).coerceIn(0.0, 1.0).toFloat()
        val leaving = (1 - motion.moodAge / 0.18).coerceIn(0.0, 1.0).toFloat()
        if (leaving > 0f) drawPersonaProps(motion.previousMood, motion.lifetime, hue, leaving)
        if (entering > 0f) drawPersonaProps(motion.mood, motion.lifetime, hue, entering)
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
    blink: Float = 0f,
    mood: PersonaMood = PersonaMood.Idle,
    previousMood: PersonaMood = mood,
    expressionProgress: Float = 1f,
    gaze: Float = 0f,
) {
    val w = size.width
    val h = size.height
    // The face borrows the body's own squash: wide and flat means narrow eyes
    // further apart, tall and thin means round eyes closer together.
    val aspect = ((maxY - minY) / max(maxX - minX, 1e-4f)).coerceIn(0.45f, 1.7f)
    // Lean, taken from where the crown sits relative to the middle.
    val tilt = (atan2(crown.x - centroid.x, max(centroid.y - crown.y, 1e-4f)) * 0.25f).coerceIn(-0.12f, 0.12f)
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
    val lod = if (unit / density < 24f) 1.35f else if (unit / density < 34f) 1.15f else 1.0f
    val radius = unit * 0.047f * lod
    val spread = unit * 0.235f / max(sqrt(aspect), 0.6f)
    val openness = max(0.02f, aspect * (1 - blink * 0.96f))
    for (index in 0 until count) {
        val offset = index.toFloat() - (count - 1).toFloat() / 2f
        val centre = place(offset * spread, -anchorHeight)
        val frame = Size(radius * 2f, max(radius * 0.10f, radius * 2f * openness))
        val topLeft = Offset(centre.x - radius, centre.y - radius * openness)
        val eye = Path().apply {
            val bounds = Rect(topLeft, frame)
            when (traits.eyeShape) {
                PersonaTraits.EyeShape.PIXEL -> addRoundRect(RoundRect(bounds, CornerRadius(radius * 0.32f)))
                PersonaTraits.EyeShape.OVAL -> addOval(Rect(topLeft + Offset(radius * 0.16f, 0f), Size(frame.width - radius * 0.32f, frame.height)))
                PersonaTraits.EyeShape.ROUND -> addOval(bounds)
            }
        }
        drawPath(eye, ink)
        if (unit / density >= 28f && openness > 0.35f) {
            clipPath(eye) {
                drawCircle(Color.White.copy(alpha = ink.alpha * 0.88f), radius * 0.22f,
                    centre + Offset(-radius * 0.20f, -radius * 0.26f))
            }
        }
    }

    if (unit / density < 21f) return
    // The persona's own mouth is a bias on the mood's, not a replacement: a
    // naturally glum character still smiles when it wins, just less widely.
    val resting = when (traits.mouth) {
        PersonaTraits.Mouth.SMILE -> 0.34f
        PersonaTraits.Mouth.FROWN -> -0.34f
        PersonaTraits.Mouth.FLAT -> -0.10f
        PersonaTraits.Mouth.DOT, null -> 0f
    }
    fun expressionFor(state: PersonaMood) = when (state) {
        PersonaMood.Failed -> -0.65f
        PersonaMood.Waiting, PersonaMood.Thinking, PersonaMood.Running, PersonaMood.Reading, PersonaMood.Typing, PersonaMood.Sketching -> 0.05f
        PersonaMood.Complete, PersonaMood.Dancing, PersonaMood.Bouncing -> 0.8f
        else -> 0.45f
    }
    val ease = expressionProgress * expressionProgress * (3 - 2 * expressionProgress)
    val expression = expressionFor(previousMood) + (expressionFor(mood) - expressionFor(previousMood)) * ease
    val curve = (expression + resting).coerceIn(-1.1f, 1.1f)
    val half = unit * 0.060f * traits.mouthWidth
    val baseY = -anchorHeight + unit * 0.12f
    val left = place(-half, baseY)
    val right = place(half, baseY)
    val bow = place(0f, baseY + curve * unit * 0.080f)
    val mouth = Path().apply {
        moveTo(left.x, left.y)
        quadraticTo(bow.x, bow.y, right.x, right.y)
    }
    drawPath(mouth, ink.copy(alpha = 0.78f), style = Stroke(width = max(1f, unit * 0.020f)))
}
