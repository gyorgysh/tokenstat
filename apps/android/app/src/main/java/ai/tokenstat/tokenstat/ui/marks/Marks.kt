// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import kotlinx.coroutines.delay
import kotlin.math.abs

/// One place cross-view UI signals live. Apple posts NotificationCenter
/// `.clientRefreshing`; the Android equivalent is a listener list.
object UiSignals {
    private val listeners = mutableListOf<() -> Unit>()

    fun onRefreshing(listener: () -> Unit) {
        synchronized(listeners) { listeners.add(listener) }
    }

    /// A refresh somebody asked for dips the logo bars and lets them back up,
    /// once.
    fun beganRefreshing() = synchronized(listeners) { listeners.forEach { it() } }
}

/// The 3-bar tokenstat logo, hand-drawn geometry transcribed from the website
/// SVG via the Apple client's `Marks.swift`. Bars rise in turn out of the
/// baseline they share.
@Composable
fun LogoMark(size: Int = 18, animated: Boolean = false, loops: Boolean = true) {
    val unit = size / 42f
    val bars = listOf(
        Triple(34f, 18f, Color(0xFFC3B0FF)),
        Triple(22f, 30f, Color(0xFF8B5CF6)),
        Triple(10f, 42f, Color(0xFFE879F9)),
    )

    // One run of the same rise for a refresh somebody pulled.
    var pulse by remember { mutableStateOf(false) }
    androidx.compose.runtime.DisposableEffect(Unit) {
        val listener = {
            if (!animated && !pulse) {
                pulse = true
            }
            Unit
        }
        UiSignals.onRefreshing(listener)
        onDispose { synchronized(UiSignals) { /* listener list lives for the process */ } }
    }
    LaunchedEffectPulse(pulse) { if (pulse) { delay(300); pulse = false } }

    Box(Modifier.size(size.dp)) {
        bars.forEachIndexed { index, (y, height, color) ->
            val looped = if (animated && loops) {
                val transition = rememberInfiniteTransition(label = "logo")
                val v by transition.animateFloat(
                    initialValue = 0.35f,
                    targetValue = 1f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(620, easing = TsMotion.easeInOut),
                        repeatMode = RepeatMode.Reverse,
                        initialStartOffset = StartOffset(index * 140),
                    ),
                    label = "logoBar",
                )
                v
            } else {
                var landed by remember { mutableStateOf(!animated) }
                LaunchedEffectLand(animated) { landed = true }
                if (landed) 1f else 0.35f
            }
            val scale = if (pulse) 0.35f else looped
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .offset(x = ((11 + index * 15 - 11) * unit).dp, y = ((y - 10) * unit).dp)
                    .size((12 * unit).dp, (height * unit).dp)
                    .clip(RoundedCornerShape((3.5 * unit).dp))
                    .background(color)
                    .graphicsLayer(
                        scaleY = scale,
                        transformOrigin = TransformOrigin(0.5f, 1f),
                    ),
            )
        }
    }
}

@Composable
private fun LaunchedEffectPulse(key: Boolean, block: suspend () -> Unit) =
    androidx.compose.runtime.LaunchedEffect(key) { block() }

@Composable
private fun LaunchedEffectLand(enabled: Boolean, block: () -> Unit) =
    androidx.compose.runtime.LaunchedEffect(enabled) {
        if (enabled) {
            delay(150)
            block()
        }
    }

/// The lowercase wordmark.
@Composable
fun Wordmark(modifier: Modifier = Modifier) {
    Text(
        "tokenstat",
        modifier = modifier,
        style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
        color = LocalTsColors.current.textPrimary,
    )
}

/// A person's avatar seat, tinted deterministically from their name over the
/// heat ramp so the same person is the same colour everywhere (the Apple
/// `Avatar` rule). Initials stand in until a real image arrives.
@Composable
fun Avatar(name: String, size: Int = 28) {
    val colors = LocalTsColors.current
    val tint = colors.heat[abs(name.hashCode()) % colors.heat.size]
    Box(
        Modifier
            .size(size.dp)
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.85f)),
        contentAlignment = Alignment.Center,
    ) {
        val initials = name.trim().split(Regex("\\s+")).take(2)
            .mapNotNull { it.firstOrNull()?.uppercaseChar() }
            .joinToString("")
        Text(
            initials.ifBlank { "?" },
            style = TextStyle(fontSize = (size * 0.38).sp, fontWeight = FontWeight.SemiBold),
            color = Color.White,
        )
    }
}
