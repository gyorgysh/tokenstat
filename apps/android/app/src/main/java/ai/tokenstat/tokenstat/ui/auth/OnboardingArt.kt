// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.auth

import androidx.compose.animation.core.CubicBezierEasing
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletAndroid
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.marks.LogoMark
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
    Intro, Agents, Heatmap, Devices, Spend, Remaining, Workspaces, Sessions, OnTheGo, Privacy, Control,
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
            OnboardingArtKind.Intro -> IntroArt(reduceMotion, active)
            OnboardingArtKind.Agents -> AgentsArt(reduceMotion, active)
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
private fun IntroArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    // Apple's spring(response 0.5, dampingFraction 0.82), staggered per tile.
    val spring = TsMotion.tunedSpring<Float>(0.5f, 0.82f)
    val tiles = listOf(
        Triple("Agents", Icons.Default.Forum, 0),
        Triple("Projects", Icons.Default.Folder, 80),
        Triple("Usage", Icons.Default.BarChart, 160),
    )
    Column(
        Modifier.width(320.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LogoMark(size = 32, animated = !reduceMotion, loops = false)
            Text(
                "Your work, together",
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            tiles.forEach { (title, icon, delayMs) ->
                var shown by remember(active) { mutableStateOf(reduceMotion || !active) }
                LaunchedEffect(active, reduceMotion) {
                    if (reduceMotion || !active) {
                        shown = true
                    } else {
                        shown = false
                        delay(delayMs.toLong())
                        shown = true
                    }
                }
                val fade by animateFloatAsState(if (shown) 1f else 0f, animationSpec = spring, label = "introFade$title")
                val rise by animateFloatAsState(if (shown) 0f else 12f, animationSpec = spring, label = "introRise$title")
                Column(
                    Modifier
                        .weight(1f)
                        .offset(y = rise.dp)
                        .alpha(fade)
                        .clip(RoundedCornerShape(18.dp))
                        .background(colors.accentSoft)
                        .padding(vertical = Space.m),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(25.dp))
                    Text(
                        title,
                        style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                }
            }
        }
    }
}

/// An illustrative conversation, with the review step visible rather than a
/// picture of an agent silently making changes. Port of `AgentsArt`.
@Composable
private fun AgentsArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    var shown by remember(active) { mutableStateOf(reduceMotion || !active) }
    LaunchedEffect(active, reduceMotion) {
        if (reduceMotion || !active) {
            shown = true
        } else {
            shown = false
            delay(200)
            shown = true
        }
    }
    // Apple's easeOut over 0.5s, after the prompt is already on screen.
    val fade by animateFloatAsState(
        if (shown) 1f else 0f,
        animationSpec = tween(500, easing = CubicBezierEasing(0f, 0f, 0.58f, 1f)),
        label = "agentsFade",
    )
    val rise by animateFloatAsState(
        if (shown) 0f else 8f,
        animationSpec = tween(500, easing = CubicBezierEasing(0f, 0f, 0.58f, 1f)),
        label = "agentsRise",
    )
    Column(
        Modifier
            .width(320.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(14.dp))
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Icon(Icons.Default.Folder, contentDescription = null, tint = colors.accent, modifier = Modifier.size(16.dp))
            Text(
                "Your project",
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Spacer(Modifier.weight(1f))
            Icon(Icons.Default.Forum, contentDescription = null, tint = colors.accent, modifier = Modifier.size(16.dp))
        }
        Text(
            "Let\u2019s work on the next idea.",
            style = TextStyle(fontSize = 14.sp),
            color = colors.textPrimary,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(colors.accentSoft)
                .padding(Space.s),
        )
        Row(
            Modifier
                .offset(y = rise.dp)
                .alpha(fade),
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = colors.accent, modifier = Modifier.size(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "Ready for your review",
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    "Read the changes. Decide what comes next.",
                    style = TextStyle(fontSize = 12.sp),
                    color = colors.textSecondary,
                )
            }
        }
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
        DeviceTile("Mac", Icons.Default.Computer, 86.dp, 58.dp, 0, reduceMotion, active)
        DeviceTile("Tablet", Icons.Default.TabletAndroid, 52.dp, 70.dp, 80, reduceMotion, active)
        DeviceTile("Phone", Icons.Default.PhoneAndroid, 34.dp, 62.dp, 160, reduceMotion, active)
    }
}

@Composable
private fun DeviceTile(
    label: String,
    icon: ImageVector,
    wide: Dp,
    tall: Dp,
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
    // Apple's spring(response 0.55, dampingFraction 0.78), staggered per tile.
    val spring = TsMotion.tunedSpring<Float>(0.55f, 0.78f)
    val rise by animateFloatAsState(
        if (shown) 0f else 18f,
        animationSpec = spring,
        label = "deviceRise",
    )
    val fade by animateFloatAsState(
        if (shown) 1f else 0f,
        animationSpec = spring,
        label = "deviceFade",
    )
    Column(
        Modifier
            .offset(y = rise.dp)
            .alpha(fade),
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
            Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(label, style = TextStyle(fontSize = 11.sp), color = colors.textSecondary)
    }
}

@Composable
private fun SpendArt(reduceMotion: Boolean, active: Boolean) {
    val bars = listOf(
        0.42f to androidx.compose.ui.graphics.Color(0xFFC3B0FF),
        0.72f to androidx.compose.ui.graphics.Color(0xFF8B5CF6),
        1.00f to androidx.compose.ui.graphics.Color(0xFFE879F9),
    )
    // Apple's spring(response 0.7, dampingFraction 0.78), each bar a tenth
    // of a second after the one before it.
    val spring = TsMotion.tunedSpring<Float>(0.7f, 0.78f)
    Row(
        Modifier.height(120.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        bars.forEachIndexed { index, (frac, color) ->
            var up by remember(active) { mutableStateOf(reduceMotion || !active) }
            LaunchedEffect(active, reduceMotion) {
                if (reduceMotion || !active) {
                    up = true
                } else {
                    up = false
                    delay(index * 100L)
                    up = true
                }
            }
            val h by animateFloatAsState(
                if (up) 110f * frac else 110f * 0.12f,
                animationSpec = spring,
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
        // Apple's easeOut over 0.9s to the 70% mark.
        animationSpec = tween(900, easing = CubicBezierEasing(0f, 0f, 0.58f, 1f)),
        label = "remaining",
    )
    // The angular accent to secondary to accent sweep from `RemainingArt`.
    val sweep = Brush.sweepGradient(listOf(colors.accent, colors.secondary, colors.accent))
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
                brush = sweep,
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
    // Folder and file glyphs, like Apple's folder.fill and doc.text rows.
    val rows = listOf(
        Triple(0, Icons.Default.Folder, "project"),
        Triple(18, Icons.Default.Folder, "src"),
        Triple(36, Icons.Default.Description, "main.rs"),
        Triple(18, Icons.Default.Description, "README.md"),
    )
    // Apple's spring(response 0.5, dampingFraction 0.82), staggered per row.
    val spring = TsMotion.tunedSpring<Float>(0.5f, 0.82f)
    Column(
        Modifier
            .width(260.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(colors.accentSoft)
            .padding(Space.l),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        rows.forEachIndexed { index, (indent, icon, name) ->
            var inView by remember(active) { mutableStateOf(reduceMotion || !active) }
            LaunchedEffect(active, reduceMotion) {
                if (reduceMotion || !active) {
                    inView = true
                } else {
                    inView = false
                    delay(index * 90L)
                    inView = true
                }
            }
            val fade by animateFloatAsState(
                if (inView) 1f else 0f,
                animationSpec = spring,
                label = "ws$index",
            )
            val shift by animateFloatAsState(
                if (inView) 0f else -10f,
                animationSpec = spring,
                label = "wsx$index",
            )
            Row(
                Modifier
                    .padding(start = indent.dp)
                    .offset(x = shift.dp)
                    .alpha(fade),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = colors.accent,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    name,
                    style = TsType.mono(17),
                    color = colors.textPrimary,
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
            // Each line fades in as it is typed, easeOut over 0.2s, while the
            // row keeps its space so the card does not jump as lines arrive.
            val lineAlpha by animateFloatAsState(
                if (lines > index) 1f else 0f,
                animationSpec = tween(200, easing = CubicBezierEasing(0f, 0f, 0.58f, 1f)),
                label = "sessionLine$index",
            )
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.alpha(lineAlpha)) {
                Text(
                    line,
                    style = TsType.mono(13),
                    color = if (index == 0) colors.accent else colors.textPrimary,
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
        GoTile(Icons.Default.PhoneAndroid, 36.dp)
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
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            GoTile(Icons.Default.Laptop, 40.dp)
            GoTile(Icons.Default.Cloud, 40.dp)
        }
    }
}

/// A device seat for the travel scene: accentSoft tile with the device glyph
/// in the accent, sized like Apple's tile (glyph at 42% of the icon size on
/// a seat 28 points larger each way).
@Composable
private fun GoTile(icon: ImageVector, iconSize: Dp) {
    val colors = LocalTsColors.current
    Box(
        Modifier
            .size(iconSize + 28.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(colors.accentSoft),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(iconSize * 0.42f),
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
    // Apple's spring(response 0.55, dampingFraction 0.7): the ring settles
    // from 0.86 and the lock from 0.88, closed once the delay lands.
    val spring = TsMotion.tunedSpring<Float>(0.55f, 0.7f)
    val ringScale by animateFloatAsState(
        if (locked) 1f else 0.86f,
        animationSpec = spring,
        label = "lockRing",
    )
    val glyphScale by animateFloatAsState(
        if (locked) 1f else 0.88f,
        animationSpec = spring,
        label = "lockGlyph",
    )
    Box(Modifier.size(132.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(132.dp)
                .clip(CircleShape)
                .background(colors.accentSoft),
        )
        Box(
            Modifier
                .size((132 * ringScale).dp)
                .clip(CircleShape)
                .border(2.dp, colors.accent.copy(alpha = 0.28f), CircleShape),
        )
        Icon(
            if (locked || reduceMotion) Icons.Default.Lock else Icons.Default.LockOpen,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier
                .size(44.dp)
                .graphicsLayer {
                    scaleX = glyphScale
                    scaleY = glyphScale
                },
        )
    }
}

@Composable
private fun ControlArt(reduceMotion: Boolean, active: Boolean) {
    val colors = LocalTsColors.current
    val rows = listOf("Private account" to true, "Sync totals" to false, "Remote reach" to false)
    // Apple's spring(response 0.5, dampingFraction 0.84), staggered per row.
    val spring = TsMotion.tunedSpring<Float>(0.5f, 0.84f)
    Column(Modifier.width(280.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        rows.forEachIndexed { index, (label, on) ->
            var inView by remember(active) { mutableStateOf(reduceMotion || !active) }
            LaunchedEffect(active, reduceMotion) {
                if (reduceMotion || !active) {
                    inView = true
                } else {
                    inView = false
                    delay(index * 80L)
                    inView = true
                }
            }
            val alpha by animateFloatAsState(
                if (inView) 1f else 0f,
                animationSpec = spring,
                label = "ctrl$index",
            )
            val rise by animateFloatAsState(
                if (inView) 0f else 10f,
                animationSpec = spring,
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
