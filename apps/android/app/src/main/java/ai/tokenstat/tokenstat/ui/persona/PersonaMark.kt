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
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlin.math.PI
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

@Composable
fun PersonaMark(
    seed: ULong,
    modifier: Modifier = Modifier,
    size: Dp = 28.dp,
    mood: PersonaMood = PersonaMood.Idle,
    settlesAfter: Double? = null,
) {
    val colors = LocalTsColors.current
    val traits = remember(seed) { PersonaTraits(seed) }
    val motion = remember(seed) { PersonaMotion(seed, traits.lumps, traits.firmness.toDouble()) }
    val tick = remember { mutableLongStateOf(0L) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val hue = traits.hue(colors.accent, colors.secondary)
    LaunchedEffect(motion, mood, lifecycle, settlesAfter) {
        val durationScale = currentCoroutineContext()[MotionDurationScale]
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { scale ->
                motion.suspendClock()
                if (scale <= 0f) {
                    motion.advance(0.0, mood, moving = false)
                    tick.longValue++
                } else {
                    var lastDraw = 0L
                    var firstFrame = -1L
                    try {
                        while (currentCoroutineContext().isActive) {
                            if (settlesAfter != null && firstFrame >= 0 &&
                                (lastDraw - firstFrame) / 1_000_000_000.0 > settlesAfter) break
                            withFrameNanos { frame ->
                                if (firstFrame < 0) firstFrame = frame
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
        tick.longValue
        drawPersonaFace(traits, hue, motion)
    }
}

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

fun DrawScope.drawPersonaFace(traits: PersonaTraits, hue: Color, motion: PersonaMotion? = null) {
    val unit = min(size.width, size.height)
    if (unit <= 1f) return
    val w = size.width
    val h = size.height

    val count = traits.lumps.size
    val cx = 0.5f
    val cy = 0.95f - 0.355f
    val nodes = (0 until count).map { index ->
        val angle = index.toFloat() * 2f * PI.toFloat() / count.toFloat()
        val reach = 0.355f * (1f + traits.lumps[index] * 0.10f)
        if (motion == null) Offset(cx + cos(angle) * reach, cy + sin(angle) * reach)
        else Offset(motion.x[index].toFloat(), motion.y[index].toFloat())
    }
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
        val origin = Offset(centroid.x * w, centroid.y * h)
        rotate(((motion?.roll ?: 0.0) * 180 / PI).toFloat(), origin) {
            drawPersonaIdleFace(traits, androidx.compose.ui.graphics.lerp(hue, Color.Black, 0.78f),
                minX, maxX, minY, maxY, centroid, crown, unit, motion)
        }
    }
    if (motion != null && unit / density >= 40f) {
        val entering = ((motion.moodAge - 0.18) / 0.35).coerceIn(0.0, 1.0).toFloat()
        val leaving = (1 - motion.moodAge / 0.18).coerceIn(0.0, 1.0).toFloat()
        if (leaving > 0f) drawPersonaProps(motion.previousMood, motion.lifetime, hue, leaving)
        if (entering > 0f) drawPersonaProps(motion.mood, motion.lifetime, hue, entering)
    }
}

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
    motion: PersonaMotion?,
) {
    val w = size.width
    val h = size.height
    val aspect = ((maxY - minY) / max(maxX - minX, 1e-4f)).coerceIn(0.45f, 1.7f)
    val lean = (atan2(crown.x - centroid.x, max(centroid.y - crown.y, 1e-4f)) * 0.25f).coerceIn(-0.12f, 0.12f)
    val tilt = lean + (motion?.headTilt ?: 0.0).toFloat()
    val heightPoints = (maxY - minY) * h
    val anchorHeight = heightPoints * 0.05f
    val origin = Offset(centroid.x * w, centroid.y * h)

    val sphereX = max(1f, (maxX - minX) * w * 0.5f)
    val sphereY = max(1f, heightPoints * 0.5f)
    val gazeX = ((motion?.gazeX ?: 0.0) + (motion?.lookX ?: 0.0)).toFloat().coerceIn(-1.3f, 1.3f)
    val gazeY = ((motion?.gazeY ?: 0.0) + (motion?.lookY ?: 0.0)).toFloat().coerceIn(-1.3f, 1.3f)
    val turn = (motion?.yaw ?: 0.0).toFloat() + gazeX * 0.30f
    val nod = gazeY * 0.20f
    class Spot(val point: Offset, val width: Float, val height: Float, val facing: Float)
    fun project(dx: Float, dy: Float): Spot {
        val theta = asin((dx / sphereX).coerceIn(-0.98f, 0.98f)) + turn
        val phi = asin((dy / sphereY).coerceIn(-0.98f, 0.98f)) + nod
        return Spot(Offset(sphereX * sin(theta), sphereY * sin(phi)), max(0f, cos(theta)), max(0.2f, cos(phi)), cos(theta))
    }
    fun place(offset: Offset): Offset = Offset(
        origin.x + offset.x * cos(tilt) - offset.y * sin(tilt),
        origin.y + offset.x * sin(tilt) + offset.y * cos(tilt),
    )
    fun onFace(dx: Float, dy: Float): Offset = place(project(dx, dy).point)

    val count = traits.eyeCount
    val lod = if (unit / density < 24f) 1.28f else if (unit / density < 34f) 1.12f else 1.0f
    val radius = unit * 0.060f * lod
    val spread = unit * 0.25f / max(sqrt(aspect), 0.6f)
    val tall = sqrt(aspect).coerceIn(0.75f, 1.3f)
    val blink = (motion?.blink ?: 0.0).toFloat()
    val wink = (motion?.wink ?: 0.0).toFloat()
    for (index in 0 until count) {
        val offset = index.toFloat() - (count - 1).toFloat() / 2f
        val side = if (offset < 0) -1 else 1
        val spot = project(offset * spread, -anchorHeight)
        if (spot.facing <= 0.02f) continue
        val winked = if (motion?.winkSide == side) wink else 0f
        drawPersonaEye(
            centre = place(spot.point), radius = radius, widthScale = spot.width,
            heightScale = spot.height * tall, side = side, motion = motion,
            blink = if (winked > 0f) max(winked, blink) else blink,
            cheer = max((motion?.cheer ?: 0.0).toFloat(), winked), tilt = tilt, unit = unit, ink = ink,
            oval = traits.eyeShape == PersonaTraits.EyeShape.OVAL, opacity = min(1f, spot.facing * 4f),
        )
    }

    val facing = min(1f, max(0f, cos(turn)) * 4f)
    if (facing <= 0.01f || unit / density < 21f) return
    val strength = ((motion?.blush ?: 0.32).toFloat()).coerceIn(0f, 1f)
    for (side in listOf(-1f, 1f)) {
        val centre = onFace(side * (spread * 0.62f + radius * 0.9f), -anchorHeight + radius * 1.25f)
        val bw = radius * 1.5f
        drawOval(
            Brush.radialGradient(
                0f to Color(0xFFD6453F).copy(alpha = 0.42f * strength * facing),
                1f to Color(0xFFD6453F).copy(alpha = 0f),
                center = centre, radius = bw * 0.62f,
            ),
            Offset(centre.x - bw / 2f, centre.y - radius * 0.39f),
            Size(bw, radius * 0.78f),
        )
    }
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
    val progress = ((motion?.moodAge ?: 1.0) / 0.4).toFloat().coerceIn(0f, 1f)
    val ease = progress * progress * (3 - 2 * progress)
    val current = motion?.mood ?: PersonaMood.Idle
    val previous = motion?.previousMood ?: current
    val expression = expressionFor(previous) + (expressionFor(current) - expressionFor(previous)) * ease
    val curve = (expression + resting).coerceIn(-1.1f, 1.1f)
    val half = unit * 0.052f * traits.mouthWidth
    val baseY = -anchorHeight + unit * 0.12f
    val left = onFace(-half, baseY)
    val right = onFace(half, baseY)
    val bow = onFace(0f, baseY + curve * unit * 0.080f)
    val mouth = Path().apply {
        moveTo(left.x, left.y)
        quadraticTo(bow.x, bow.y, right.x, right.y)
    }
    drawPath(mouth, ink.copy(alpha = 0.78f * facing), style = Stroke(width = max(1f, unit * 0.020f), cap = StrokeCap.Round))
}

private fun DrawScope.drawPersonaEye(
    centre: Offset,
    radius: Float,
    widthScale: Float,
    heightScale: Float,
    side: Int,
    motion: PersonaMotion?,
    blink: Float,
    cheer: Float,
    tilt: Float,
    unit: Float,
    ink: Color,
    oval: Boolean,
    opacity: Float,
) {
    val wide = ((motion?.openness ?: 1.0).toFloat()).coerceIn(0f, 1.3f)
    val closing = blink.coerceIn(0f, 1f)
    val ew = radius * 2f * (if (oval) 0.86f else 1f) * widthScale * (1f + closing * 0.10f)
    val eh = radius * 2f * (if (oval) 1.14f else 1f) * min(1.4f, heightScale * max(1f, wide)) * (1f - min(0f, blink) * 0.9f)
    val open = (min(wide, 1f) * (1f - closing)).coerceIn(0f, 1f)
    val squint = ((motion?.squint ?: 0.0).toFloat()).coerceIn(0f, 0.8f)
    val smile = max(cheer, squint * 0.45f).coerceIn(0f, 1f)
    val droop = ((motion?.droop ?: 0.0).toFloat()).coerceIn(0f, 1f)
    val focus = ((motion?.focus ?: 0.0).toFloat()).coerceIn(0f, 1f) * (1f - droop) * 0.55f

    rotate(tilt * 180f / PI.toFloat(), centre) {
        val minX = centre.x - ew / 2f; val maxX = centre.x + ew / 2f
        val minY = centre.y - eh / 2f; val maxY = centre.y + eh / 2f
        val meet = minY + eh * 0.68f
        val shut = 1f - open
        val upper = minY + (meet - minY) * shut
        val innerX = if (side < 0) maxX else minX
        val outerX = if (side < 0) minX else maxX
        val innerY = upper + eh * 0.30f * focus
        val outerY = upper + eh * 0.40f * droop
        fun lidY(x: Float) = innerY + (outerY - innerY) * (x - innerX) / (outerX - innerX)
        val left = minX - ew
        val right = maxX + ew
        val arch = lidY(centre.x) - eh * (1.6f * shut * (1f - shut) + 0.26f * min(1f, focus + droop))
        val lowerBase = maxY - (maxY - meet) * shut - eh * 0.30f * squint
        val lowerEdge = max(lowerBase - eh * 0.10f * smile, max(lidY(left), lidY(right)))
        val lowerPeak = max(lowerBase - eh * 1.35f * smile, arch)
        val gap = Path().apply {
            moveTo(left, lidY(left))
            quadraticTo(centre.x, arch, right, lidY(right))
            lineTo(right, lowerEdge)
            quadraticTo(centre.x, lowerPeak, left, lowerEdge)
            close()
        }
        if (open > 0.04f) {
            clipPath(gap) {
                drawOval(ink.copy(alpha = ink.alpha * opacity), Offset(minX, minY), Size(ew, eh))
                if (unit / density >= 22f && open > 0.3f) {
                    val size = min(ew, eh)
                    drawCircle(Color.White.copy(alpha = 0.92f * opacity), size * 0.15f,
                        Offset(centre.x - ew * 0.22f, minY + eh * 0.30f))
                    drawCircle(Color.White.copy(alpha = 0.62f * opacity), size * 0.065f,
                        Offset(centre.x + ew * 0.16f, minY + eh * 0.64f))
                }
            }
        }
        val line = ((0.24f - open) / 0.18f).coerceIn(0f, 1f)
        if (line > 0f) {
            val sag = eh * 0.22f * (if (smile > 0.5f) -1f else 1f) - eh * 0.10f * droop
            val arc = Path().apply {
                moveTo(minX, meet - sag * 0.25f)
                quadraticTo(centre.x, meet + sag, maxX, meet - sag * 0.25f)
            }
            drawPath(arc, ink.copy(alpha = ink.alpha * line * opacity),
                style = Stroke(width = max(1f, unit * 0.024f), cap = StrokeCap.Round))
        }
    }
}
