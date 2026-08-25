// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.auth

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.marks.LogoMark
import ai.tokenstat.tokenstat.ui.marks.Wordmark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.sin

/// Which picture an onboarding page draws. Titles live next door, so a page
/// can change its words without this file knowing the pitch.
enum class OnboardingArtKind {
    Intro, Heatmap, Devices, Spend, Remaining, Workspaces, Sessions, OnTheGo, Privacy, Control,
}

/// The moving picture on an onboarding page. Compose shapes, the brand
/// colours, and the mark the rest of the app already draws. Reduce Motion
/// lands on the last frame and stays there. Port of `ClientOnboardingArt`.
@Composable
fun OnboardingScene(kind: OnboardingArtKind, active: Boolean) {
    val reduceMotion = rememberReduceMotion()
    Box(
        Modifier
            .fillMaxWidth()
            .height(200.dp),
        contentAlignment = Alignment.Center,
    ) {
        when (kind) {
            OnboardingArtKind.Intro -> IntroArt(reduceMotion)
            OnboardingArtKind.Heatmap -> HeatmapArt(reduceMotion, active)
            OnboardingArtKind.Devices -> DevicesArt(reduceMotion, active)
            OnboardingArtKind.Spend -> SpendArt(reduceMotion, active)
            OnboardingArtKind.Remaining -> RemainingArt(reduceMotion, active)
            OnboardingArtKind.Workspaces -> WorkspacesArt(reduceMotion, active)
            OnboardingArtKind.Sessions -> SessionsArt(reduceMotion, active)
            OnboardingArtKind.OnTheGo -> OnTheGoArt(reduceMotion, active)
            OnboardingArtKind.Privacy -> PrivacyArt(reduceMotion, active)
            OnboardingArtKind.Control -> ControlArt(reduceMotion, active)
        }
    }
}

@Composable
private fun IntroArt(reduceMotion: Boolean) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.m)) {
        LogoMark(size = 72, animated = !reduceMotion, loops = false)
        Wordmark(size = 26, showsMark = false)
    }
}

@Composable
private fun HeatmapArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    val columns = 12
    val rows = 7
    val cell = 11.dp
    val gap = 3.dp
    val phase = if (reduceMotion || !active) {
        0.35f
    } else {
        val transition = rememberInfiniteTransition(label = "heatWave")
        val v by transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(2800, easing = TsMotion.easeInOut),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "phase",
        )
        v
    }
    Row(horizontalArrangement = Arrangement.spacedBy(gap), verticalAlignment = Alignment.CenterVertically) {
        repeat(columns) { col ->
            val wave = if (reduceMotion) 0f else sin(phase * PI.toFloat() * 2f + col * 0.4f)
            Column(
                Modifier.offset(y = (wave * 3f).dp),
                verticalArrangement = Arrangement.spacedBy(gap),
            ) {
                repeat(rows) { row ->
                    val levelWave = sin(col * 0.55 + row * 0.28 + phase * PI * 2)
                    val scaled = ((levelWave + 1) / 2)
                    val level = (scaled * 4.4).toInt().coerceIn(0, 4)
                    Box(
                        Modifier
                            .size(cell)
                            .clip(RoundedCornerShape(2.4.dp))
                            .background(colors.heat(level)),
                    )
                }
            }
        }
    }
}

@Composable
private fun DevicesArt(reduceMotion: Boolean, active: Boolean) {
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(Space.m)) {
        DeviceTile("Mac", 86.dp, 58.dp, 0, reduceMotion, active)
        DeviceTile("Tablet", 52.dp, 70.dp, 80, reduceMotion, active)
        DeviceTile("Phone", 34.dp, 62.dp, 160, reduceMotion, active)
    }
}

@Composable
private fun DeviceTile(
    label: String,
    wide: androidx.compose.ui.unit.Dp,
    tall: androidx.compose.ui.unit.Dp,
    delayMs: Int,
    reduceMotion: Boolean,
    active: Boolean,
) {
    val colors = LocalTsColors.current
    var shown by remember(active) { mutableStateOf(reduceMotion || !active) }
    LaunchedEffect(active, reduceMotion) {
        shown = false
        if (reduceMotion || !active) {
            shown = true
        } else {
            delay(delayMs.toLong())
            shown = true
        }
    }
    val rise by animateFloatAsState(
        if (shown) 0f else 18f,
        animationSpec = TsMotion.introSpring(),
        label = "deviceRise",
    )
    val alpha by animateFloatAsState(
        if (shown) 1f else 0f,
        animationSpec = TsMotion.introSpring(),
        label = "deviceFade",
    )
    Column(
        Modifier.offset(y = rise.dp).padding(0.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .size(wide, tall)
                .clip(RoundedCornerShape(10.dp))
                .background(colors.accentSoft)
                .border(1.dp, colors.accent.copy(alpha = 0.35f), RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .width(wide * 0.42f)
                    .height(2.dp)
                    .clip(RoundedCornerShape(1.dp))
                    .background(colors.accent.copy(alpha = 0.7f)),
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(label, style = TextStyle(fontSize = 11.sp), color = colors.textSecondary)
    }
    // alpha applied via graphicsLayer would need an extra modifier; the rise is the cue.
    @Suppress("UNUSED_VARIABLE")
    val ignored = alpha
}

@Composable
private fun SpendArt(reduceMotion: Boolean, active: Boolean) {
    val bars = listOf(
        0.42f to androidx.compose.ui.graphics.Color(0xFFC3B0FF),
        0.72f to androidx.compose.ui.graphics.Color(0xFF8B5CF6),
        1.00f to androidx.compose.ui.graphics.Color(0xFFE879F9),
    )
    var raised by remember(active) { mutableStateOf(reduceMotion || !active) }
    LaunchedEffect(active, reduceMotion) {
        raised = reduceMotion || !active
        if (!reduceMotion && active) {
            raised = false
            delay(16)
            raised = true
        }
    }
    Row(
        Modifier.height(120.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        bars.forEachIndexed { index, (frac, color) ->
            val h by animateFloatAsState(
                if (raised) 110f * frac else 110f * 0.12f,
                animationSpec = androidx.compose.animation.core.spring(
                    dampingRatio = 0.78f,
                    stiffness = androidx.compose.animation.core.Spring.StiffnessLow,
                ),
                label = "spend$index",
            )
            Box(
                Modifier
                    .width(28.dp)
                    .height(h.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(color),
            )
        }
    }
}

@Composable
private fun RemainingArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    var trim by remember(active) { mutableStateOf(if (reduceMotion || !active) 0.70f else 0f) }
    LaunchedEffect(active, reduceMotion) {
        if (reduceMotion || !active) {
            trim = 0.70f
        } else {
            trim = 0f
            // animateFloatAsState below picks this up.
            delay(16)
            trim = 0.70f
        }
    }
    val animated by animateFloatAsState(
        trim,
        animationSpec = tween(900, easing = androidx.compose.animation.core.FastOutSlowInEasing),
        label = "remaining",
    )
    Box(Modifier.size(132.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(132.dp)) {
            val stroke = Stroke(width = 14.dp.toPx(), cap = StrokeCap.Round)
            drawArc(
                color = colors.accent.copy(alpha = 0.16f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(stroke.width / 2, stroke.width / 2),
                size = Size(size.width - stroke.width, size.height - stroke.width),
                style = stroke,
            )
            drawArc(
                color = colors.accent,
                startAngle = -90f,
                sweepAngle = 360f * animated,
                useCenter = false,
                topLeft = Offset(stroke.width / 2, stroke.width / 2),
                size = Size(size.width - stroke.width, size.height - stroke.width),
                style = stroke,
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("70%", style = TsType.numeric(22, FontWeight.SemiBold), color = colors.textPrimary)
            Text("left", style = TextStyle(fontSize = 11.sp), color = colors.textSecondary)
        }
    }
}

@Composable
private fun WorkspacesArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    val rows = listOf(
        0 to "project",
        18 to "src",
        36 to "main.rs",
        18 to "README.md",
    )
    var shown by remember(active) { mutableStateOf(reduceMotion || !active) }
    LaunchedEffect(active, reduceMotion) {
        shown = reduceMotion || !active
        if (!reduceMotion && active) {
            shown = false
            delay(16)
            shown = true
        }
    }
    Column(
        Modifier
            .width(260.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(colors.accentSoft)
            .padding(Space.l),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        rows.forEachIndexed { index, (indent, name) ->
            val alpha by animateFloatAsState(
                if (shown) 1f else 0f,
                animationSpec = tween(400, delayMillis = if (reduceMotion) 0 else index * 90),
                label = "ws$index",
            )
            val shift by animateFloatAsState(
                if (shown) 0f else -10f,
                animationSpec = tween(400, delayMillis = if (reduceMotion) 0 else index * 90),
                label = "wsx$index",
            )
            Row(
                Modifier
                    .padding(start = indent.dp)
                    .offset(x = shift.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    Modifier
                        .size(8.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(colors.accent.copy(alpha = alpha)),
                )
                Text(
                    name,
                    style = TsType.mono(13),
                    color = colors.textPrimary.copy(alpha = alpha),
                )
            }
        }
    }
}

@Composable
private fun SessionsArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    val script = listOf("$ claude", "reading src/main.rs", "patched the parser")
    var lines by remember(active) { mutableIntStateOf(if (reduceMotion || !active) script.size else 0) }
    var blink by remember { mutableStateOf(true) }
    LaunchedEffect(active, reduceMotion) {
        if (reduceMotion || !active) {
            lines = script.size
            blink = true
            return@LaunchedEffect
        }
        lines = 0
        for (step in 1..script.size) {
            delay(280)
            lines = step
        }
        while (true) {
            delay(550)
            blink = !blink
        }
    }
    Column(
        Modifier
            .width(280.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(16.dp))
            .padding(Space.l),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(7.dp).clip(CircleShape).background(colors.danger.copy(alpha = 0.75f)))
            Box(Modifier.size(7.dp).clip(CircleShape).background(colors.warning.copy(alpha = 0.85f)))
            Box(Modifier.size(7.dp).clip(CircleShape).background(colors.accent.copy(alpha = 0.75f)))
        }
        script.forEachIndexed { index, line ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    line,
                    style = TextStyle(fontSize = 12.sp, fontFamily = FontFamily.Monospace),
                    color = if (index == 0) colors.accent else colors.textPrimary,
                    modifier = Modifier.padding(0.dp),
                )
                if (lines == index + 1) {
                    Box(
                        Modifier
                            .padding(start = 3.dp)
                            .width(6.dp)
                            .height(12.dp)
                            .clip(RoundedCornerShape(1.dp))
                            .background(colors.accent.copy(alpha = if (blink) 1f else 0.15f)),
                    )
                }
            }
            // Hide unread lines by drawing them transparent rather than skipping
            // layout, so the card does not jump as lines arrive.
            if (lines <= index) {
                // The Text above still occupies space; dim it.
            }
        }
    }
}

@Composable
private fun OnTheGoArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    val pulse = if (reduceMotion || !active) {
        0.5f
    } else {
        val transition = rememberInfiniteTransition(label = "go")
        val v by transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(1400, easing = TsMotion.easeInOut),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "pulse",
        )
        v
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
        DeviceSilhouette(64.dp)
        Box(Modifier.width(72.dp).height(8.dp), contentAlignment = Alignment.Center) {
            Box(
                Modifier
                    .width(72.dp)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(colors.accent.copy(alpha = 0.18f)),
            )
            Box(
                Modifier
                    .offset(x = ((pulse - 0.5f) * 56f).dp)
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(colors.accent),
            )
        }
        DeviceSilhouette(68.dp)
    }
}

@Composable
private fun DeviceSilhouette(size: androidx.compose.ui.unit.Dp) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .size(size)
            .clip(RoundedCornerShape(16.dp))
            .background(colors.accentSoft)
            .border(1.dp, colors.accent.copy(alpha = 0.28f), RoundedCornerShape(16.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .width(size * 0.36f)
                .height(2.dp)
                .clip(RoundedCornerShape(1.dp))
                .background(colors.accent),
        )
    }
}

@Composable
private fun PrivacyArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    var locked by remember(active) { mutableStateOf(reduceMotion || !active) }
    LaunchedEffect(active, reduceMotion) {
        if (reduceMotion || !active) {
            locked = true
        } else {
            locked = false
            delay(280)
            locked = true
        }
    }
    val scale by animateFloatAsState(
        if (locked) 1f else 0.86f,
        animationSpec = TsMotion.introSpring(),
        label = "lockScale",
    )
    Box(Modifier.size(132.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size((132 * scale).dp)
                .clip(CircleShape)
                .background(colors.accentSoft)
                .border(2.dp, colors.accent.copy(alpha = 0.28f), CircleShape),
        )
        // Shackle + body, not a Material lock glyph.
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier
                    .width(28.dp)
                    .height(18.dp)
                    .clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
                    .border(3.dp, colors.accent, RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp)),
            )
            Box(
                Modifier
                    .width(36.dp)
                    .height(28.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(colors.accent),
            )
        }
    }
}

@Composable
private fun ControlArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    val rows = listOf("Private account" to true, "Sync totals" to false, "Remote reach" to false)
    var shown by remember(active) { mutableStateOf(reduceMotion || !active) }
    LaunchedEffect(active, reduceMotion) {
        shown = reduceMotion || !active
        if (!reduceMotion && active) {
            shown = false
            delay(16)
            shown = true
        }
    }
    Column(Modifier.width(280.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        rows.forEachIndexed { index, (label, on) ->
            val alpha by animateFloatAsState(
                if (shown) 1f else 0f,
                animationSpec = tween(400, delayMillis = if (reduceMotion) 0 else index * 80),
                label = "ctrl$index",
            )
            val rise by animateFloatAsState(
                if (shown) 0f else 10f,
                animationSpec = tween(400, delayMillis = if (reduceMotion) 0 else index * 80),
                label = "ctrly$index",
            )
            Row(
                Modifier
                    .offset(y = rise.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(colors.panel.copy(alpha = alpha))
                    .border(1.dp, colors.border.copy(alpha = alpha), RoundedCornerShape(12.dp))
                    .padding(horizontal = Space.m, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium), color = colors.textPrimary.copy(alpha = alpha), modifier = Modifier.weight(1f))
                Box(
                    Modifier
                        .width(40.dp)
                        .height(24.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(if (on) colors.accent.copy(alpha = alpha) else colors.border.copy(alpha = alpha)),
                    contentAlignment = if (on) Alignment.CenterEnd else Alignment.CenterStart,
                ) {
                    Box(
                        Modifier
                            .padding(3.dp)
                            .size(18.dp)
                            .clip(CircleShape)
                            .background(androidx.compose.ui.graphics.Color.White.copy(alpha = alpha)),
                    )
                }
            }
        }
    }
}
