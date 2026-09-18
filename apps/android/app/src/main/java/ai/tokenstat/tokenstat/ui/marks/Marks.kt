// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.marks

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.Animatable
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.R
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.TsColors
import ai.tokenstat.tokenstat.ui.theme.TsMotion
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import kotlinx.coroutines.delay

/// One place cross-view UI signals live. Apple posts NotificationCenter
/// `.clientRefreshing`; the Android equivalent is a listener list.
object UiSignals {
    private val listeners = mutableListOf<() -> Unit>()

    /// Registers a listener, returning an unsubscribe function the caller
    /// must run when it leaves, so a recomposed logo does not stack listeners.
    fun onRefreshing(listener: () -> Unit): () -> Unit {
        synchronized(listeners) { listeners.add(listener) }
        return { synchronized(listeners) { listeners.remove(listener) } }
    }

    /// A refresh somebody asked for dips the logo bars and lets them back up,
    /// once.
    fun beganRefreshing() = synchronized(listeners) { listeners.forEach { it() } }
}

/// The logo bar timings, transcribed from `LogoMark` in the Apple client's
/// `Marks.swift` so the launch loop, the one-shot rise and the refresh dip
/// move the same way on both platforms. Pinned by `LaunchMotionTest`.
object LogoMotion {
    /// Repeating launch loop: easeInOut 0.62s autoreverse, staggered 0.14s.
    const val loopMs = 620
    const val loopStaggerMs = 140

    /// One rise that lands and holds: easeInOut 1.2s, staggered 0.15s.
    const val oneShotMs = 1200
    const val oneShotStaggerMs = 150L

    /// Refresh dip: easeInOut 0.26s, staggered 0.07s, down to 0.35 and back.
    const val dipMs = 260
    const val dipStaggerMs = 70L
    const val dipScale = 0.35f

    /// How long the dip is held before the bars come back up. Apple sleeps
    /// 300ms between setting and clearing the pulse.
    const val dipHoldMs = 300L
}

/// The 3-bar tokenstat logo, hand-drawn geometry transcribed from the website
/// SVG via the Apple client's `Marks.swift`. Bars rise in turn out of the
/// baseline they share.
@Composable
fun LogoMark(size: Int = 18, animated: Boolean = false, loops: Boolean = true) {
    val reduceMotion = rememberReduceMotion()
    val unit = size / 42f
    val bars = listOf(
        Triple(34f, 18f, Color(0xFFC3B0FF)),
        Triple(22f, 30f, Color(0xFF8B5CF6)),
        Triple(10f, 42f, Color(0xFFE879F9)),
    )

    // One run of the same rise for a refresh somebody pulled.
    var pulse by remember { mutableStateOf(false) }
    androidx.compose.runtime.DisposableEffect(Unit) {
        val unsubscribe = UiSignals.onRefreshing {
            if (!animated && !pulse) {
                pulse = true
            }
        }
        onDispose { unsubscribe() }
    }
    LaunchedEffect(pulse) {
        if (pulse) {
            delay(LogoMotion.dipHoldMs)
            pulse = false
        }
    }

    Box(Modifier.size(size.dp)) {
        bars.forEachIndexed { index, (y, height, color) ->
            // The repeating rise, or one rise that lands and holds. Reduce
            // Motion lands on the last frame and stays there.
            val looped = if (animated && loops && !reduceMotion) {
                val transition = rememberInfiniteTransition(label = "logo")
                val v by transition.animateFloat(
                    initialValue = LogoMotion.dipScale,
                    targetValue = 1f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(LogoMotion.loopMs, easing = TsMotion.easeInOut),
                        repeatMode = RepeatMode.Reverse,
                        initialStartOffset = StartOffset(index * LogoMotion.loopStaggerMs),
                    ),
                    label = "logoBar",
                )
                v
            } else {
                val land = remember { Animatable(if (animated && !reduceMotion) LogoMotion.dipScale else 1f) }
                LaunchedEffect(animated, index) {
                    if (animated && !reduceMotion) {
                        land.snapTo(LogoMotion.dipScale)
                        kotlinx.coroutines.delay(index * LogoMotion.oneShotStaggerMs)
                        land.animateTo(1f, tween(LogoMotion.oneShotMs, easing = TsMotion.easeInOut))
                    } else {
                        land.snapTo(1f)
                    }
                }
                land.value
            }
            // The refresh dip: each bar sinks to 0.35 and comes back up over
            // 260ms, a beat after the one before it, like `Marks.swift`.
            val dip = remember { Animatable(1f) }
            LaunchedEffect(pulse) {
                delay(index * LogoMotion.dipStaggerMs)
                dip.animateTo(
                    if (pulse) LogoMotion.dipScale else 1f,
                    tween(LogoMotion.dipMs, easing = TsMotion.easeInOut),
                )
            }
            val scale = if (pulse || dip.value != 1f) dip.value else looped
            // The dip drives the geometry, not a layer transform: the bars
            // shorten toward the baseline they share, so a scale the renderer
            // drops cannot leave them standing. Same picture as a bottom
            // pivoted scaleY, corner radius included.
            val barHeight = height * scale
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .offset(x = ((11 + index * 15 - 11) * unit).dp, y = ((y - 10 + height - barHeight) * unit).dp)
                    .size((12 * unit).dp, (barHeight * unit).dp)
                    .clip(RoundedCornerShape((3.5 * unit * scale).dp))
                    .background(color),
            )
        }
    }
}

/// The lowercase wordmark. `token` in primary, `stat` in the accent, matching
/// `Marks.swift`. The phone toolbar passes a larger size; the bars are optional
/// so a lockup that already placed the mark does not draw it twice.
@Composable
fun Wordmark(
    modifier: Modifier = Modifier,
    size: Int = 18,
    fills: Boolean = false,
    showsMark: Boolean = false,
) {
    val colors = LocalTsColors.current
    val face = TextStyle(fontSize = (size * 0.88).sp, fontWeight = FontWeight.Bold)
    Row(
        modifier.then(if (fills) Modifier.fillMaxWidth() else Modifier),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showsMark) {
            LogoMark(size = size)
            Spacer(Modifier.width((size * 0.75f).dp))
        }
        Text("token", style = face, color = colors.textPrimary)
        Text("stat", style = face, color = colors.accent)
        if (fills) Spacer(Modifier.weight(1f))
    }
}

/// A product-owned vector mark for a feature surface, ported from
/// `FeatureMark` in `Marks.swift`: the glyph at 62% on a tile of its own tint
/// at 12%, cornered at 28%. Names are the Apple asset names (`mark_host`),
/// resolved to the converted drawables.
fun featureMarkRes(name: String): Int = when (name) {
    "mark_account" -> R.drawable.feature_mark_account
    "mark_activity" -> R.drawable.feature_mark_activity
    "mark_agent" -> R.drawable.feature_mark_agent
    "mark_archive" -> R.drawable.feature_mark_archive
    "mark_automation" -> R.drawable.feature_mark_automation
    "mark_cache" -> R.drawable.feature_mark_cache
    "mark_chat" -> R.drawable.feature_mark_chat
    "mark_day" -> R.drawable.feature_mark_day
    "mark_delete" -> R.drawable.feature_mark_delete
    "mark_device" -> R.drawable.feature_mark_device
    "mark_done" -> R.drawable.feature_mark_done
    "mark_examples" -> R.drawable.feature_mark_examples
    "mark_folder" -> R.drawable.feature_mark_folder
    "mark_host" -> R.drawable.feature_mark_host
    "mark_insights" -> R.drawable.feature_mark_insights
    "mark_license" -> R.drawable.feature_mark_license
    "mark_local" -> R.drawable.feature_mark_local
    "mark_note" -> R.drawable.feature_mark_note
    "mark_paused" -> R.drawable.feature_mark_paused
    "mark_pin" -> R.drawable.feature_mark_pin
    "mark_plan" -> R.drawable.feature_mark_plan
    "mark_running" -> R.drawable.feature_mark_running
    "mark_scheduler" -> R.drawable.feature_mark_scheduler
    "mark_sync" -> R.drawable.feature_mark_sync
    "mark_terminal" -> R.drawable.feature_mark_terminal
    "mark_todo" -> R.drawable.feature_mark_todo
    "mark_week" -> R.drawable.feature_mark_week
    "mark_workflow" -> R.drawable.feature_mark_workflow
    else -> 0
}

@Composable
fun FeatureMark(name: String, tint: Color = LocalTsColors.current.accent, size: Int = 18) {
    val res = featureMarkRes(name)
    // A name with no drawing behind it used to paint the tile anyway, which
    // is a blank accent square: worse than nothing, and it looks like the
    // image failed to load rather than like a typo in a mark name.
    if (res == 0) return
    Box(
        Modifier
            .size(size.dp)
            .clip(RoundedCornerShape((size * 0.28f).dp))
            .background(tint.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center,
    ) {
        if (res != 0) {
            Icon(
                painterResource(res),
                contentDescription = null,
                modifier = Modifier.size((size * 0.62f).dp),
                tint = tint,
            )
        }
    }
}

/// Initials from a display name, the same function the Apple `Avatar` uses:
/// the first letters of the first two words, uppercased. Nil when there is no
/// name to take them from, so the caller falls through to the handle.
fun avatarInitials(name: String?): String? {
    val parts = (name ?: "").trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    val first = parts.firstOrNull()?.firstOrNull() ?: return null
    val second = if (parts.size > 1) parts[1].firstOrNull()?.toString().orEmpty() else ""
    return "$first$second".uppercase()
}

/// The account, reached from the leading edge of every screen. Ported from
/// `AvatarButton.swift`: the monogram on an accent-to-secondary gradient, the
/// fetched picture over it once it has arrived, and a person glyph inside an
/// accent ring when signed out. The picture reads the shared cache
/// synchronously, so an already fetched face paints on the first frame instead
/// of flashing the letter while a new fetch spins up.
@Composable
fun Avatar(
    name: String,
    size: Int = 28,
    avatarUrl: String? = null,
    signedIn: Boolean = true,
    /// The bubble's colour. The app's accent for our own picture; a colour
    /// drawn from the identity where several people appear in one list, so a
    /// row is recognisable before the name is read. Port of `Avatar.tint`.
    tint: Color? = null,
    /// Beside its own name in text, a face is decoration and announcing it
    /// again is noise. The account button, which is the face on its own,
    /// leaves this false and keeps its label.
    decorative: Boolean = false,
) {
    val colors = LocalTsColors.current
    val bubble = tint ?: colors.accent
    val context = LocalContext.current
    val raw = avatarUrl?.trim()?.takeIf { it.isNotEmpty() }
    var picture: Bitmap? by remember(raw) { mutableStateOf(raw?.let { AvatarCache.cached(it) }) }
    LaunchedEffect(raw) {
        if (raw == null || picture != null) return@LaunchedEffect
        val loaded = AvatarCache.image(context, raw)
        // Only land while this URL is still the one on show, so a slow
        // answer for the previous account cannot cover the new one.
        if (loaded != null) picture = loaded
    }
    val drawn: Dp = size.dp
    Box(
        Modifier
            .size(drawn)
            .then(
                if (decorative) {
                    Modifier
                } else {
                    Modifier.semantics {
                        contentDescription = if (signedIn) "Account, $name" else "Sign in to tokenstat"
                    }
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(drawn)
                .clip(CircleShape)
                .background(
                    androidx.compose.ui.graphics.Brush.linearGradient(
                        listOf(bubble, colors.secondary),
                    ),
                    alpha = if (signedIn) 1f else 0.14f,
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (signedIn) {
                Text(
                    avatarInitials(name) ?: "t",
                    style = TextStyle(fontSize = (size * 0.42f).sp, fontWeight = FontWeight.SemiBold),
                    color = Color.White,
                )
            } else {
                Icon(
                    Icons.Default.Person,
                    contentDescription = null,
                    modifier = Modifier.size((size * 0.44f).dp),
                    tint = colors.accent,
                )
            }
        }
        if (signedIn && picture != null) {
            // Over the monogram, not instead of it, so a slow or failed load
            // shows the letter rather than a hole.
            Image(
                picture!!.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.size(drawn).clip(CircleShape),
                contentScale = ContentScale.Crop,
            )
        }
        if (!signedIn) {
            Box(
                Modifier
                    .size(drawn)
                    .border(1.5.dp, colors.accent.copy(alpha = 0.55f), CircleShape),
            )
        }
    }
}

/// A stable colour for a person, from the app's own ramp. Port of
/// `Avatar.tint(for:)`.
///
/// Hashed over the bytes rather than with `hashCode`, which is not promised to
/// be stable across runs: the same author would get a different colour on the
/// next launch, and a mark that moves is not a mark. The ramp's first two
/// steps are left out — they are the heatmap's quiet-day greys, and a letter
/// in one of them is a letter nobody can read.
fun avatarTint(identity: String, colors: TsColors): Color {
    val palette = colors.heat.drop(2) + listOf(colors.warning, colors.danger)
    if (palette.isEmpty()) return colors.accent
    var hash = 5381UL
    for (byte in identity.lowercase().toByteArray()) {
        hash = hash * 33UL + byte.toUByte().toULong()
    }
    return palette[(hash % palette.size.toULong()).toInt()]
}
