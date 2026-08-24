// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.theme

import android.provider.Settings
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp

/// Spacing scale. Four points, so layouts stay on a rhythm instead of
/// accumulating one-off paddings.
object Space {
    val xs = Dp(4f)
    val s = Dp(8f)
    val m = Dp(12f)
    val l = Dp(20f)
    val xl = Dp(32f)
}

/// Corner radius for cards and panels.
val cardRadius = Dp(14f)

/// Padding inside a card.
val cardPadding = Dp(16f)

object TsMotion {
    /// `smoothIn` arrival, the app-wide content transition: a short fade with a
    /// small rise. Collapses to a plain fade when Reduce Motion is on.
    const val arriveMillis = 220

    /// Skeleton pulse period (Apple: easeInOut 0.95s autoreverse).
    const val pulseMillis = 950

    /// Breathing live indicators (Apple: 1.1s loop).
    const val breatheMillis = 1100

    /// Root shell door transitions (Apple: easeInOut 0.28).
    const val doorMillis = 280

    /// Toast slide+fade (Apple: snappy 0.25).
    const val toastMillis = 250

    val easeInOut = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

    fun <T> arrive() = tween<T>(arriveMillis, easing = LinearEasing)

    fun <T> door() = tween<T>(doorMillis, easing = easeInOut)

    /// The staggered intro spring family from ClientOnboardingArt /
    /// ClientEmptyArt (response 0.5-0.7s, dampingFraction 0.7-0.84).
    fun <T> introSpring() = spring<T>(
        dampingRatio = 0.78f,
        stiffness = Spring.StiffnessLow,
        visibilityThreshold = null,
    )
}

/// Whether the user has asked the system for reduced motion (the accessibility
/// "remove animations" switch zeroes the animator duration scale). Every
/// ambient loop and content transition must collapse when this is set, exactly
/// like SwiftUI's `accessibilityReduceMotion`.
@Composable
fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    return remember {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }
}

@Composable
fun riseInPx(): Int {
    val density = LocalDensity.current
    return with(density) { Space.xs.roundToPx() }
}

/// The `smoothIn` enter transition for loaded content replacing a skeleton.
@Composable
fun smoothEnter(reduceMotion: Boolean): EnterTransition {
    val rise = riseInPx()
    return if (reduceMotion) fadeIn(TsMotion.arrive())
    else fadeIn(TsMotion.arrive()) + slideInVertically(TsMotion.arrive()) { rise }
}
